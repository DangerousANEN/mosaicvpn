"""T0.7 bot logic tests: ADMIN_IDS, is_admin, ref_stats_incr SQL-injection guard,
and broadcast error-resilience patterns.

bot.py connects to Telegram at import time, so we extract the functions
the same way test_link_codes.py does.
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


# ── ref_stats_incr + ref_stats_get ──
_BLOCK_REFS = _extract("def ref_stats_incr(", "def ref_leaderboard_top(")
_ns = {
    "sqlite3": sqlite3,
    "datetime": datetime,
    "logging": __import__("logging"),
    "logger": __import__("logging").getLogger("test"),
}
exec(compile(_BLOCK_REFS, BOT_PY, "exec"), _ns)
ref_stats_incr = _ns["ref_stats_incr"]
ref_stats_get = _ns["ref_stats_get"]

SCHEMA_REFS = """
CREATE TABLE IF NOT EXISTS referral_stats (
    referrer_id INTEGER PRIMARY KEY,
    clicks INTEGER DEFAULT 0,
    joined INTEGER DEFAULT 0,
    paid INTEGER DEFAULT 0,
    bonus_days_earned INTEGER DEFAULT 0
)
"""


class RefStatsIncrTest(unittest.TestCase):
    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        conn = sqlite3.connect(self.db)
        conn.execute(SCHEMA_REFS)
        conn.commit()
        conn.close()
        _ns["DB_PATH"] = self.db

    def tearDown(self):
        try:
            os.unlink(self.db)
        except OSError:
            pass

    def test_valid_fields_increment(self):
        ref_stats_incr(1, "clicks", by=1)
        ref_stats_incr(1, "clicks", by=1)
        ref_stats_incr(1, "paid", by=1)
        ref_stats_incr(1, "bonus_days_earned", by=30)
        stats = ref_stats_get(1)
        self.assertEqual(stats["clicks"], 2)
        self.assertEqual(stats["paid"], 1)
        self.assertEqual(stats["bonus_days_earned"], 30)

    def test_invalid_field_is_ignored(self):
        """The whitelist guard must reject arbitrary field names — this is
        the SQL-injection fix. Before the guard, ref_stats_incr(0, '1=1; DROP
        TABLE referral_stats--') would have executed the injected SQL."""
        ref_stats_incr(1, "clicks", by=1)
        # Injection attempt — must be a no-op
        ref_stats_incr(1, "1=1; DROP TABLE referral_stats--", by=1)
        ref_stats_incr(1, "nonexistent_column", by=1)
        ref_stats_incr(1, "paid' || 'x", by=1)
        # Stats should still be intact (table not dropped, no junk columns)
        stats = ref_stats_get(1)
        self.assertEqual(stats["clicks"], 1)
        self.assertEqual(stats["paid"], 0)

    def test_all_four_allowed_fields(self):
        for f in ["clicks", "joined", "paid", "bonus_days_earned"]:
            ref_stats_incr(2, f, by=5)
        stats = ref_stats_get(2)
        self.assertEqual(stats["clicks"], 5)
        self.assertEqual(stats["joined"], 5)
        self.assertEqual(stats["paid"], 5)
        self.assertEqual(stats["bonus_days_earned"], 5)


# ── Source-level checks (no runtime import needed) ──

class SourceIntegrityTest(unittest.TestCase):
    """Verify the fixes are present in bot.py source."""

    def test_admin_ids_is_defined(self):
        """ADMIN_IDS must be defined before it's used in admin_alert / is_admin."""
        self.assertIn("ADMIN_IDS = {", _src)
        self.assertIn("MOSAIC_ADMIN_IDS", _src)

    def test_is_admin_checks_admin_ids(self):
        """is_admin must check the in-memory ADMIN_IDS set, not just admins.txt."""
        self.assertIn("if telegram_id in ADMIN_IDS:", _src)
        self.assertNotIn('f.write("583864', _src, "old hardcoded default admin ID removed")

    def test_all_requests_have_timeout(self):
        """Every requests.get/post/patch call must have a timeout parameter."""
        import re
        # Find all requests.X calls and check timeout is nearby
        pattern = r"requests\.(get|post|patch|put|delete)\s*\("
        for m in re.finditer(pattern, _src):
            # Grab 300 chars after the call to see if timeout= is present
            snippet = _src[m.start():m.start() + 300]
            # If it's a one-liner, check up to the closing paren
            self.assertIn("timeout", snippet,
                          f"requests.{m.group(1)} call without timeout at offset {m.start()}")

    def test_skip_pending_in_polling(self):
        self.assertIn("skip_pending=True", _src)

    def test_ref_stats_incr_has_whitelist(self):
        self.assertIn("allowed_fields", _src)
        self.assertIn("if field not in allowed_fields", _src)

    def test_admin_alert_has_fallback(self):
        """admin_alert must fallback to plain text if Markdown send fails."""
        alert_start = _src.index("def admin_alert(")
        alert_block = _src[alert_start:alert_start + 600]
        # Must have a second send_message without parse_mode (the fallback)
        self.assertIn("bot.send_message(admin_id, f\"🚨 АЛЕРТ", alert_block)

    def test_broadcast_has_429_handling(self):
        """Broadcast must handle 429 rate limits and Markdown parse fallback."""
        bc_start = _src.index("def handle_broadcast(")
        bc_end = _src.index("def send_buy_menu(", bc_start)
        bc_block = _src[bc_start:bc_end]
        self.assertIn("429", bc_block, "broadcast must handle 429 rate limits")
        self.assertIn("parse_mode", bc_block)

    def test_idempotency_guard_still_present(self):
        self.assertIn("WHERE invoice_id = ? AND status = ?", _src)
        claim = _src.index('if not update_invoice_status(invoice_id, "paid"):')
        extend = _src.index("updated = api_extend_user(username, days)")
        self.assertLess(claim, extend)

    def test_lava_card_and_sbp_are_separate_user_choices(self):
        self.assertIn('"card": frozenset({"card", "card_ru", "mir_card", "mir_pay"})', _src)
        self.assertIn('"sbp": frozenset({"sbp", "sber_pay"})', _src)
        self.assertIn('callback_data=f"lava_card_', _src)
        self.assertIn('callback_data=f"lava_sbp_', _src)
        self.assertIn('payment_method=payment_method', _src)

    def test_lava_invoice_restricts_include_service_to_selected_method(self):
        create_start = _src.index("def create_lava_invoice(")
        create_end = _src.index("def verify_lava_webhook(", create_start)
        create_block = _src[create_start:create_end]
        self.assertIn("active_services = [service for service in active_services if service in allowed]", create_block)
        self.assertIn('"includeService": active_services', create_block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
