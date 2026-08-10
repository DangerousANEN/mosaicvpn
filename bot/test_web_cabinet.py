"""Tests for the web cabinet HTTP endpoints: /api/session, /api/billing/profile,
/api/billing/payments. Uses a temp SQLite database and mocks the Remnawave API
so no external network is needed."""

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from threading import Thread
from unittest.mock import patch, MagicMock

# Make bot/ importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Mock telebot before importing bot.bot — the bot module imports telebot
# at the top level, and we don't have it installed locally.
if "telebot" not in sys.modules:
    telebot_mock = MagicMock()
    telebot_mock.TeleBot = MagicMock()
    telebot_mock.types = MagicMock()
    telebot_mock.apihelper = MagicMock()
    sys.modules["telebot"] = telebot_mock

# Also mock other potentially missing deps
for mod in ["dateutil", "dateutil.parser", "requests", "psycopg2"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

# Set required env vars before importing bot.bot (it checks them at import time)
os.environ.setdefault("MOSAIC_BOT_TOKEN", "test_token_12345")
os.environ.setdefault("MOSAIC_REMNAWAVE_TOKEN", "test_remnawave_token")

# Import after path is set and mocks are in place
import bot.bot as bot_module


# Global counter for unique IDs across test classes
_inv_counter = [1000]
_user_counter = [10000]
_code_counter = [0]
_LINK_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def _next_inv_id():
    _inv_counter[0] += 1
    return _inv_counter[0]


def _next_user_id():
    _user_counter[0] += 1
    return _user_counter[0]


def _next_code():
    """Generate a unique code using only the link-code alphabet (no I, L, O, 0, 1)."""
    import random
    _code_counter[0] += 1
    seed = _code_counter[0]
    rng = random.Random(seed)
    return ''.join(rng.choices(_LINK_ALPHABET, k=6))


class TestWebCabinetBase(unittest.TestCase):
    """Shared setUp/tearDown: create a fresh temp DB with init_db() schema."""

    @classmethod
    def setUpClass(cls):
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        cls.db_path = path
        bot_module.DB_PATH = path
        bot_module.init_db()
        # Enable WAL for better concurrency (HTTP server + test writes)
        conn = sqlite3.connect(path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.close()

    @classmethod
    def tearDownClass(cls):
        try:
            os.unlink(cls.db_path)
            for ext in ["-wal", "-shm"]:
                p = cls.db_path + ext
                if os.path.exists(p):
                    os.unlink(p)
        except (PermissionError, OSError):
            pass

    def _db_insert(self, sql, params=()):
        conn = sqlite3.connect(self.db_path, timeout=30)
        c = conn.cursor()
        c.execute(sql, params)
        conn.commit()
        conn.close()


class TestWebSession(TestWebCabinetBase):
    def test_create_and_get_session(self):
        """create_web_session inserts a row; get_web_session reads it back."""
        token, expires = bot_module.create_web_session(123, "alice")
        self.assertTrue(token)
        self.assertTrue(expires)
        session = bot_module.get_web_session(token)
        self.assertIsNotNone(session)
        self.assertEqual(session["telegram_id"], 123)
        self.assertEqual(session["username"], "alice")

    def test_get_session_invalid_token(self):
        self.assertIsNone(bot_module.get_web_session("nonexistent_token"))
        self.assertIsNone(bot_module.get_web_session(""))
        self.assertIsNone(bot_module.get_web_session(None))


class TestPaymentsHistory(TestWebCabinetBase):
    def test_payments_for_user_with_data(self):
        uid = _next_user_id()
        conn = sqlite3.connect(self.db_path, timeout=30)
        c = conn.cursor()
        c.execute("INSERT OR REPLACE INTO users (telegram_id, username) VALUES (?, ?)", (uid, 'alice'))
        c.execute("INSERT OR REPLACE INTO invoices (invoice_id, telegram_id, amount, days, status, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                  (_next_inv_id(), uid, 100.0, 30, 'paid', '2026-01-01'))
        c.execute("INSERT OR REPLACE INTO invoices (invoice_id, telegram_id, amount, days, status, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                  (_next_inv_id(), uid, 30.0, 7, 'pending', '2026-02-01'))
        conn.commit()
        conn.close()

        payments = bot_module.get_payments_history(uid)
        self.assertEqual(len(payments), 2)
        # DESC by created_at — first is newest (2026-02-01, 30 rubles)
        self.assertEqual(payments[0]["amount"], 30)
        self.assertEqual(payments[1]["amount"], 100)

    def test_payments_for_user_with_no_data(self):
        payments = bot_module.get_payments_history(999)
        self.assertEqual(len(payments), 0)


class TestHTTPEndpoints(TestWebCabinetBase):
    """Spin up the real HTTP server on a random port and test endpoints."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()

        # Find a free port
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        cls.port = sock.getsockname()[1]
        sock.close()

        from http.server import HTTPServer
        cls.server = HTTPServer(("127.0.0.1", cls.port), bot_module.StatsRequestHandler)
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=3)
        super().tearDownClass()

    def _post(self, path, body):
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = resp.read().decode("utf-8")
        conn.close()
        try:
            parsed = json.loads(data) if data else {}
        except json.JSONDecodeError:
            parsed = {}
        return resp.status, parsed

    def _get(self, path):
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", path)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8")
        conn.close()
        return resp.status, json.loads(data) if data else {}

    def test_session_create_with_valid_code(self):
        """POST /api/session with a valid pairing code returns a token."""
        import datetime
        uid = _next_user_id()
        code = _next_code()
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).isoformat()
        self._db_insert("INSERT OR REPLACE INTO users (telegram_id, username) VALUES (?, ?)", (uid, "testuser"))
        self._db_insert("INSERT OR REPLACE INTO link_codes (code, telegram_id, username, expires_at) VALUES (?, ?, ?, ?)",
                        (code, uid, "testuser", expires))

        status, data = self._post("/api/session", {"code": code})
        self.assertEqual(status, 200)
        self.assertTrue(data.get("token"))
        self.assertEqual(data["telegram_id"], uid)
        self.assertEqual(data["username"], "testuser")

    def test_session_create_with_invalid_code(self):
        status, data = self._post("/api/session", {"code": "NOTREAL"})
        self.assertEqual(status, 404)
        self.assertEqual(data["error"], "not_found")

    def test_session_create_missing_code(self):
        status, data = self._post("/api/session", {})
        self.assertEqual(status, 400)
        self.assertEqual(data["error"], "code required")

    def test_session_create_reuse_used_code(self):
        """A code that was already redeemed should return 409."""
        import datetime
        uid = _next_user_id()
        code = _next_code()
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).isoformat()
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self._db_insert("INSERT OR REPLACE INTO link_codes (code, telegram_id, username, expires_at, used_at) VALUES (?, ?, ?, ?, ?)",
                        (code, uid, "useduser", expires, now))

        status, data = self._post("/api/session", {"code": code})
        self.assertEqual(status, 409)
        self.assertEqual(data["error"], "used")

    def test_billing_profile_without_token(self):
        status, data = self._get("/api/billing/profile")
        self.assertEqual(status, 401)

    def test_billing_profile_with_token(self):
        """Create a session, then fetch the profile."""
        import datetime
        uid = _next_user_id()
        code = _next_code()
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).isoformat()
        self._db_insert("INSERT OR REPLACE INTO users (telegram_id, username, short_uuid) VALUES (?, ?, ?)",
                        (uid, "profuser", "abc123"))
        self._db_insert("INSERT OR REPLACE INTO link_codes (code, telegram_id, username, expires_at) VALUES (?, ?, ?, ?)",
                        (code, uid, "profuser", expires))

        status, data = self._post("/api/session", {"code": code})
        self.assertEqual(status, 200)
        token = data["token"]

        with patch.object(bot_module, 'api_get_user', return_value=None):
            status, data = self._get(f"/api/billing/profile?token={token}")
        self.assertEqual(status, 200)
        self.assertEqual(data["telegram_id"], uid)
        self.assertEqual(data["username"], "profuser")
        self.assertEqual(data["short_uuid"], "abc123")

    def test_billing_profile_with_expired_token(self):
        """An expired web session should return 401."""
        import datetime
        past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).isoformat()
        self._db_insert("INSERT OR REPLACE INTO web_sessions (token, telegram_id, username, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                        ("expired_token_xyz", 111, "ghost", "2026-01-01T00:00:00+00:00", past))

        status, data = self._get("/api/billing/profile?token=expired_token_xyz")
        self.assertEqual(status, 401)

    def test_billing_payments_with_token(self):
        """Payments endpoint returns list of invoices."""
        import datetime
        uid = _next_user_id()
        code = _next_code()
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).isoformat()
        self._db_insert("INSERT OR REPLACE INTO users (telegram_id, username) VALUES (?, ?)", (uid, "payuser"))
        self._db_insert("INSERT OR REPLACE INTO invoices (invoice_id, telegram_id, amount, days, status, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                        (_next_inv_id(), uid, 50.0, 15, "paid", "2026-03-01"))
        self._db_insert("INSERT OR REPLACE INTO link_codes (code, telegram_id, username, expires_at) VALUES (?, ?, ?, ?)",
                        (code, uid, "payuser", expires))

        status, data = self._post("/api/session", {"code": code})
        self.assertEqual(status, 200)
        token = data["token"]

        status, data = self._get(f"/api/billing/payments?token={token}")
        self.assertEqual(status, 200)
        self.assertTrue(len(data.get("payments", [])) >= 1)

    def test_options_cors(self):
        """OPTIONS should return 204 with CORS headers."""
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("OPTIONS", "/api/session")
        resp = conn.getresponse()
        self.assertEqual(resp.status, 204)
        cors_header = resp.headers.get("Access-Control-Allow-Origin", "")
        self.assertEqual(cors_header, "https://sub.zxc1x1.ru")
        conn.close()

    def test_404_for_unknown_post(self):
        status, data = self._post("/api/unknown", {"x": 1})
        self.assertEqual(status, 404)

    def test_404_for_unknown_get(self):
        status, _ = self._get("/api/unknown")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
