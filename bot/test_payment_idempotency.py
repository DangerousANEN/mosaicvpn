"""T0.6 payment-idempotency tests.

bot.py connects to Telegram at import time, so these tests extract the invoice
helpers out of it and exercise them against a real SQLite file — the same
approach as test_link_codes.py. test_source_in_sync fails if bot.py drifts away
from what is tested here.

What is under test: a paid invoice must credit the subscription exactly once,
even though the bot runs under `Restart=always` and polls in a background
thread, so the same paid invoice can legitimately be observed twice.
"""
import datetime
import os
import sqlite3
import tempfile
import unittest

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")

_src = open(BOT_PY, encoding="utf-8").read()


def _extract(start_marker, end_marker):
    i = _src.index(start_marker)
    j = _src.index(end_marker, i)
    return _src[i:j]


_BLOCK = _extract("def save_invoice(", "def get_all_tg_users(")
for required in ("def update_invoice_status(", "def get_pending_invoices("):
    if required not in _BLOCK:
        raise SystemExit(f"could not locate {required} in bot.py")

_ns = {
    "sqlite3": sqlite3,
    "datetime": datetime,
    "logging": __import__("logging"),
}
exec(compile(_BLOCK, BOT_PY, "exec"), _ns)

save_invoice = _ns["save_invoice"]
get_pending_invoices = _ns["get_pending_invoices"]
update_invoice_status = _ns["update_invoice_status"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS invoices (
    invoice_id INTEGER PRIMARY KEY,
    telegram_id INTEGER,
    amount REAL,
    months REAL,
    days INTEGER,
    status TEXT,
    created_at TEXT,
    promo_code TEXT,
    bonus_days INTEGER DEFAULT 0
)
"""


class PaymentIdempotencyTest(unittest.TestCase):
    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        conn = sqlite3.connect(self.db)
        conn.execute(SCHEMA)
        conn.commit()
        conn.close()
        _ns["DB_PATH"] = self.db

    def tearDown(self):
        try:
            os.unlink(self.db)
        except OSError:
            pass

    def _status(self, invoice_id):
        conn = sqlite3.connect(self.db)
        row = conn.execute(
            "SELECT status FROM invoices WHERE invoice_id = ?", (invoice_id,)
        ).fetchone()
        conn.close()
        return row[0] if row else None

    # ── the core guarantee ──

    def test_first_claim_succeeds_second_is_refused(self):
        save_invoice(1001, 42, 199.0, 1, 30)
        self.assertTrue(update_invoice_status(1001, "paid"))
        self.assertFalse(
            update_invoice_status(1001, "paid"),
            "second claim must be refused, otherwise a restart credits the user twice",
        )
        self.assertEqual(self._status(1001), "paid")

    def test_accrual_runs_exactly_once_across_two_poll_cycles(self):
        """Simulates the real loop: two cycles see the same paid invoice."""
        save_invoice(1002, 43, 199.0, 1, 30)
        credited_days = []

        def poll_cycle():
            # Mirrors polling_invoices_thread: claim first, credit only if claimed.
            for invoice_id, telegram_id, days in get_pending_invoices():
                if not update_invoice_status(invoice_id, "paid"):
                    continue
                credited_days.append(days)

        poll_cycle()
        poll_cycle()  # a restart, or an overlapping cycle

        self.assertEqual(
            credited_days, [30], "subscription must be credited exactly once per payment"
        )

    def test_pending_list_excludes_claimed_invoice(self):
        save_invoice(1003, 44, 99.0, 0.5, 15)
        self.assertEqual(len(get_pending_invoices()), 1)
        update_invoice_status(1003, "paid")
        self.assertEqual(get_pending_invoices(), [])

    # ── the guard must not break the other transitions ──

    def test_expired_and_cancelled_transitions_still_work(self):
        for invoice_id, status in ((1004, "expired"), (1005, "cancelled")):
            save_invoice(invoice_id, 45, 199.0, 1, 30)
            self.assertTrue(update_invoice_status(invoice_id, status))
            self.assertEqual(self._status(invoice_id), status)

    def test_cannot_revive_a_paid_invoice_as_pending(self):
        save_invoice(1006, 46, 199.0, 1, 30)
        update_invoice_status(1006, "paid")
        self.assertFalse(update_invoice_status(1006, "expired"))
        self.assertEqual(self._status(1006), "paid")

    def test_expect_none_forces_the_write(self):
        """The escape hatch for admin corrections must still bypass the guard."""
        save_invoice(1007, 47, 199.0, 1, 30)
        update_invoice_status(1007, "paid")
        self.assertTrue(update_invoice_status(1007, "refunded", expect=None))
        self.assertEqual(self._status(1007), "refunded")

    def test_unknown_invoice_reports_no_change(self):
        self.assertFalse(update_invoice_status(999999, "paid"))

    # ── regression guard on bot.py itself ──

    def test_source_in_sync(self):
        """The SQL guard and the claim-before-credit order must stay in bot.py.

        Testing the extracted copy proves the helper is correct; this proves the
        real polling loop actually uses it in the safe order. Without this the
        helper could stay perfect while the caller reverts to crediting first.
        """
        self.assertTrue(
            "WHERE invoice_id = ? AND status = ?" in _src,
            "the status guard disappeared from update_invoice_status",
        )
        claim = _src.index('if not update_invoice_status(invoice_id, "paid"):')
        extend = _src.index("updated = api_extend_user(username, days)")
        self.assertLess(
            claim, extend, "the invoice must be claimed before the subscription is extended"
        )
        self.assertIn("continue", _src[claim:extend])


if __name__ == "__main__":
    unittest.main(verbosity=2)
