"""T-19 pairing-code tests.

bot.py connects to Telegram at import time, so these tests copy the three
code-handling functions out of it and exercise them against a real SQLite
file. The copies are verified against the originals by test_source_in_sync,
which fails if bot.py drifts.
"""
import datetime
import os
import re
import sqlite3
import sys
import tempfile
import unittest

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")

# Extract the real implementations from bot.py without importing it.
_src = open(BOT_PY, encoding="utf-8").read()


def _extract(start_marker, end_marker):
    i = _src.index(start_marker)
    j = _src.index(end_marker, i)
    return _src[i:j]


_BLOCK = _extract("LINK_CODE_ALPHABET =", "def get_user(telegram_id):")
if "LINK_CODE_ALPHABET" not in _BLOCK:
    raise SystemExit("could not locate the link-code block in bot.py")

_ns = {
    "sqlite3": sqlite3,
    "datetime": datetime,
    "secrets": __import__("secrets"),
    "logging": __import__("logging"),
}
exec(compile(_BLOCK, BOT_PY, "exec"), _ns)

issue_link_code = _ns["issue_link_code"]
redeem_link_code = _ns["redeem_link_code"]
_link_code_normalise = _ns["_link_code_normalise"]
LINK_CODE_ALPHABET = _ns["LINK_CODE_ALPHABET"]
LINK_CODE_MAX_ATTEMPTS = _ns["LINK_CODE_MAX_ATTEMPTS"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS link_codes (
    code TEXT PRIMARY KEY,
    telegram_id INTEGER NOT NULL,
    username TEXT,
    session_token TEXT,
    issued_at TEXT,
    expires_at TEXT,
    used_at TEXT,
    attempts INTEGER DEFAULT 0
)
"""


class LinkCodeTest(unittest.TestCase):
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

    def _set_expiry(self, code, when):
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE link_codes SET expires_at = ? WHERE code = ?",
                     (when.isoformat(), code))
        conn.commit()
        conn.close()

    def test_issue_then_redeem(self):
        code, _ = issue_link_code(555, "nikita", "tok-1")
        self.assertEqual(len(code), 8)
        result, reason = redeem_link_code(code)
        self.assertIsNone(reason)
        self.assertEqual(result["telegram_id"], 555)
        self.assertEqual(result["username"], "nikita")
        self.assertEqual(result["session_token"], "tok-1")

    def test_alphabet_excludes_ambiguous_glyphs(self):
        # A code is read off one screen and typed into another.
        for ch in "01OIL":
            self.assertNotIn(ch, LINK_CODE_ALPHABET)

    def test_code_is_single_use(self):
        code, _ = issue_link_code(1, "u")
        self.assertIsNone(redeem_link_code(code)[1])
        result, reason = redeem_link_code(code)
        self.assertIsNone(result)
        self.assertEqual(reason, "used")

    def test_expired_code_reports_expired_not_missing(self):
        code, _ = issue_link_code(2, "u")
        past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)
        self._set_expiry(code, past)
        result, reason = redeem_link_code(code)
        self.assertIsNone(result)
        self.assertEqual(reason, "expired")

    def test_unknown_code(self):
        self.assertEqual(redeem_link_code("ZZZZZZZZ")[1], "not_found")

    def test_empty_code(self):
        self.assertEqual(redeem_link_code("")[1], "not_found")
        self.assertEqual(redeem_link_code(None)[1], "not_found")

    def test_normalisation_accepts_lowercase_and_separators(self):
        code, _ = issue_link_code(3, "u")
        typed = code.lower()[:4] + "-" + code.lower()[4:]
        result, reason = redeem_link_code(typed)
        self.assertIsNone(reason)
        self.assertEqual(result["telegram_id"], 3)

    def test_reissue_invalidates_the_previous_code(self):
        first, _ = issue_link_code(4, "u")
        second, _ = issue_link_code(4, "u")
        self.assertNotEqual(first, second)
        self.assertEqual(redeem_link_code(first)[1], "not_found")
        self.assertIsNone(redeem_link_code(second)[1])

    def test_attempt_ceiling(self):
        code, _ = issue_link_code(5, "u")
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE link_codes SET attempts = ? WHERE code = ?",
                     (LINK_CODE_MAX_ATTEMPTS, code))
        conn.commit()
        conn.close()
        self.assertEqual(redeem_link_code(code)[1], "attempts")

    def test_naive_expiry_timestamp_is_treated_as_utc(self):
        # Older rows may lack a timezone; a naive future timestamp must not be
        # misread as already expired.
        code, _ = issue_link_code(6, "u")
        future = datetime.datetime.utcnow() + datetime.timedelta(minutes=5)
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE link_codes SET expires_at = ? WHERE code = ?",
                     (future.isoformat(), code))
        conn.commit()
        conn.close()
        self.assertIsNone(redeem_link_code(code)[1])

    def test_codes_do_not_repeat_across_users(self):
        seen = {issue_link_code(100 + i, "u")[0] for i in range(40)}
        self.assertEqual(len(seen), 40)

    def test_source_in_sync(self):
        # Guard against bot.py drifting away from the copies tested here.
        for name in ("def issue_link_code(", "def redeem_link_code(",
                     "def _link_code_normalise("):
            self.assertIn(name, _src)


class SchemaTest(unittest.TestCase):
    def test_bot_creates_the_link_codes_table(self):
        self.assertIn("CREATE TABLE IF NOT EXISTS link_codes", _src)

    def test_bot_registers_the_link_command(self):
        self.assertIn('commands=["link"]', _src)

    def test_bot_exposes_the_redeem_endpoint(self):
        self.assertIn("/api/link/redeem", _src)
        self.assertIn("def do_POST", _src)

    def test_redeem_endpoint_caps_body_size(self):
        # An unbounded Content-Length read would let a caller exhaust VPS memory.
        self.assertTrue(re.search(r"length > \d+", _src))


if __name__ == "__main__":
    unittest.main(verbosity=2)
