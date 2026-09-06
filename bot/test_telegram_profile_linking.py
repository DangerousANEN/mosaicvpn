"""Tests for the website-profile ↔ Telegram binding contract.

The production bot opens Telegram polling at import time, so these tests execute
only the exact persistence helpers from bot.py against an isolated SQLite DB.
"""
import datetime
import hashlib
import hmac
import os
import re
import sqlite3
import tempfile
import unittest

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
_SOURCE = open(BOT_PY, encoding="utf-8").read()


def _extract(start, end):
    return _SOURCE[_SOURCE.index(start):_SOURCE.index(end, _SOURCE.index(start))]


_HELPERS = _extract("LINK_CODE_ALPHABET =", "def get_user(telegram_id):")
_NS = {
    "sqlite3": sqlite3,
    "datetime": datetime,
    "secrets": __import__("secrets"),
    "logging": __import__("logging"),
    "re": re,
    "hashlib": hashlib,
    "hmac": hmac,
}
exec(compile(_HELPERS, BOT_PY, "exec"), _NS)

issue_telegram_link_code = _NS["issue_telegram_link_code"]
claim_telegram_link_code = _NS["claim_telegram_link_code"]
get_telegram_account_link = _NS["get_telegram_account_link"]
resolve_telegram_account_id = _NS["resolve_telegram_account_id"]
unlink_telegram_account = _NS["unlink_telegram_account"]
redeem_link_code = _NS["redeem_link_code"]

SCHEMA = """
CREATE TABLE users (
    telegram_id INTEGER PRIMARY KEY,
    username TEXT,
    short_uuid TEXT,
    language TEXT,
    trial_used INTEGER,
    created_at TEXT,
    referrer_id INTEGER
);
CREATE TABLE link_codes (
    code TEXT PRIMARY KEY,
    telegram_id INTEGER NOT NULL,
    username TEXT,
    session_token TEXT,
    issued_at TEXT,
    expires_at TEXT,
    used_at TEXT,
    attempts INTEGER DEFAULT 0
);
CREATE TABLE telegram_link_codes (
    code TEXT PRIMARY KEY,
    account_id INTEGER NOT NULL,
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE telegram_account_links (
    telegram_id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL UNIQUE,
    telegram_username TEXT,
    linked_at TEXT NOT NULL
);
"""


class TelegramProfileLinkingTest(unittest.TestCase):
    def setUp(self):
        fd, self.db_path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript(SCHEMA)
        _NS["DB_PATH"] = self.db_path
        self.website_account_id = -101

    def tearDown(self):
        import gc
        gc.collect()
        try:
            os.unlink(self.db_path)
        except OSError:
            pass

    def test_cabinet_code_binds_one_unbound_telegram_chat(self):
        code, _ = issue_telegram_link_code(self.website_account_id)
        result, reason = claim_telegram_link_code(code, 100200300, "mosaic_user")
        self.assertIsNone(reason)
        self.assertEqual(result["account_id"], self.website_account_id)
        self.assertEqual(resolve_telegram_account_id(100200300), self.website_account_id)
        link = get_telegram_account_link(self.website_account_id)
        self.assertEqual(link["telegram_id"], 100200300)
        self.assertEqual(link["username"], "mosaic_user")

    def test_telegram_binding_code_cannot_be_redeemed_as_client_code(self):
        code, _ = issue_telegram_link_code(self.website_account_id)
        _, reason = redeem_link_code(code)
        self.assertEqual(reason, "not_found")

    def test_code_is_single_use(self):
        code, _ = issue_telegram_link_code(self.website_account_id)
        self.assertIsNone(claim_telegram_link_code(code, 111, "first")[1])
        _, reason = claim_telegram_link_code(code, 222, "second")
        self.assertEqual(reason, "used")

    def test_existing_standalone_telegram_profile_is_not_replaced(self):
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                "INSERT INTO users (telegram_id, username, short_uuid) VALUES (?, ?, ?)",
                (555, "tg_555", "feed-555"),
            )
        code, _ = issue_telegram_link_code(self.website_account_id)
        _, reason = claim_telegram_link_code(code, 555, "existing")
        self.assertEqual(reason, "telegram_profile_exists")
        self.assertEqual(resolve_telegram_account_id(555), 555)

    def test_unlink_removes_the_binding(self):
        code, _ = issue_telegram_link_code(self.website_account_id)
        self.assertIsNone(claim_telegram_link_code(code, 777, "detach")[1])
        self.assertTrue(unlink_telegram_account(self.website_account_id))
        self.assertEqual(resolve_telegram_account_id(777), 777)
        self.assertIsNone(get_telegram_account_link(self.website_account_id))


if __name__ == "__main__":
    unittest.main(verbosity=2)
