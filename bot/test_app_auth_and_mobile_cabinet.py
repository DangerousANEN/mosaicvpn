"""Regression coverage for website-first app login and hosted mobile cabinet APIs.

The tests use a temporary SQLite authority and a local HTTP server; no real
Remnawave or payment-provider request is permitted during the suite.
"""

import datetime
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer
from threading import Thread
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

if "telebot" not in sys.modules:
    telebot_mock = MagicMock()
    telebot_mock.TeleBot = MagicMock()
    telebot_mock.types = MagicMock()
    telebot_mock.apihelper = MagicMock()
    sys.modules["telebot"] = telebot_mock
for module_name in ["dateutil", "dateutil.parser", "requests", "psycopg2"]:
    if module_name not in sys.modules:
        sys.modules[module_name] = MagicMock()

os.environ.setdefault("MOSAIC_BOT_TOKEN", "test_token_12345")
os.environ.setdefault("MOSAIC_REMNAWAVE_TOKEN", "test_remnawave_token")

import bot.bot as bot_module


class AppAuthAndCabinetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        descriptor, cls.db_path = tempfile.mkstemp(suffix=".db")
        os.close(descriptor)
        bot_module.DB_PATH = cls.db_path
        bot_module.init_db()
        cls.server = HTTPServer(("127.0.0.1", 0), bot_module.StatsRequestHandler)
        cls.port = cls.server.server_address[1]
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=3)
        for suffix in ("", "-wal", "-shm"):
            try:
                os.unlink(cls.db_path + suffix)
            except OSError:
                pass

    def setUp(self):
        self.telegram_id = 701001 + hash(self.id()) % 100000
        self.username = f"tg_{self.telegram_id}"
        bot_module.save_user(self.telegram_id, self.username, f"sub_{self.telegram_id}")
        self.session_token, _ = bot_module.create_web_session(self.telegram_id, self.username)

    def _post(self, path, payload):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("POST", path, json.dumps(payload), {"Content-Type": "application/json"})
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        connection.close()
        return response.status, json.loads(body) if body else {}

    def _get(self, path):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        connection.close()
        return response.status, json.loads(body) if body else {}

    def test_app_auth_code_is_state_bound_single_use(self):
        state = "a" * 48
        code = bot_module.issue_app_auth_code(self.session_token, state)
        self.assertTrue(code)
        account, error = bot_module.redeem_app_auth_code(code, "b" * 48)
        self.assertIsNone(account)
        self.assertEqual(error, "state_mismatch")
        account, error = bot_module.redeem_app_auth_code(code, state)
        self.assertIsNone(error)
        self.assertEqual(account["telegram_id"], self.telegram_id)
        account, error = bot_module.redeem_app_auth_code(code, state)
        self.assertIsNone(account)
        self.assertEqual(error, "used")

    def test_app_auth_exchange_never_puts_session_token_in_callback_contract(self):
        state = "c" * 48
        status, issued = self._post("/api/app-auth/issue", {"token": self.session_token, "state": state})
        self.assertEqual(status, 200)
        self.assertIn("code", issued)
        self.assertNotIn("session_token", issued)
        status, exchanged = self._post("/api/app-auth/exchange", {"code": issued["code"], "state": state})
        self.assertEqual(status, 200)
        self.assertEqual(exchanged["direct_token"], f"sub_{self.telegram_id}")
        self.assertTrue(exchanged["session_token"])
        self.assertNotEqual(exchanged["session_token"], self.session_token)

    def test_checkout_options_require_session_and_describe_lava(self):
        status, _ = self._get("/api/checkout/options")
        self.assertEqual(status, 401)
        status, body = self._get(f"/api/checkout/options?token={self.session_token}")
        self.assertEqual(status, 200)
        self.assertEqual(body["providers"][0]["id"], "lava")
        self.assertTrue(body["providers"][0]["available"])

    @patch.object(bot_module, "api_get_user", return_value={"status": "DISABLED"})
    @patch.object(bot_module, "api_disable_user", return_value={"ok": True})
    def test_freeze_uses_authenticated_session_and_provider_action(self, disabled, remote):
        status, body = self._post("/api/account/freeze", {"token": self.session_token})
        self.assertEqual(status, 200)
        disabled.assert_called_once_with(self.username)
        self.assertEqual(body["account"]["status"], "frozen")

    @patch.object(bot_module, "create_lava_invoice", return_value={
        "internal_id": "int_1", "provider_id": "provider_1", "order_id": "order_1", "payment_url": "https://payments.example/pay/1"
    })
    @patch.object(bot_module, "save_lava_invoice")
    def test_mobile_checkout_returns_checkout_url(self, save_invoice, create_invoice):
        status, body = self._post("/api/checkout/create", {
            "token": self.session_token, "provider": "lava", "amount_rub": 30,
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["provider"], "lava")
        self.assertEqual(body["amount_rub"], 30)
        self.assertEqual(body["checkout_url"], "https://payments.example/pay/1")
        create_invoice.assert_called_once()
        save_invoice.assert_called_once()

    @patch.object(bot_module, "api_get_user", return_value={"shortUuid": "new_sub_uuid"})
    @patch.object(bot_module, "api_revoke_user_subscription", return_value={"ok": True})
    def test_link_rotation_requires_provider_to_confirm_new_value(self, revoke, remote):
        status, body = self._post("/api/subscription/link/rotate", {"token": self.session_token})
        self.assertEqual(status, 200)
        self.assertEqual(body["short_uuid"], "new_sub_uuid")
        revoke.assert_called_once_with(self.username)
        self.assertEqual(bot_module.get_user(self.telegram_id)["short_uuid"], "new_sub_uuid")


if __name__ == "__main__":
    unittest.main(verbosity=2)
