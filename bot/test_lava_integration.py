"""Regression tests for the two-store Lava integration.

The tests never call Lava or Remnawave. They use fake keys and a temporary SQLite
schema matching the migrated production invoices table.
"""
import hashlib
import hmac
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

os.environ.setdefault("MOSAIC_BOT_TOKEN", "123456:test-token")
os.environ.setdefault("MOSAIC_REMNAWAVE_TOKEN", "test-token")

import bot.bot as bot_module


class LavaIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.old_config = bot_module.LAVA_STORE_CONFIG
        bot_module.LAVA_STORE_CONFIG = {
            "site": {
                "shop_id": "site-shop",
                "secret_key": "site-secret",
                "additional_key": "site-additional",
                "success_url": "https://example.invalid/success",
                "fail_url": "https://example.invalid/fail",
                "webhook_path": "/api/billing/lava/webhook/site",
            },
            "bot": {
                "shop_id": "bot-shop",
                "secret_key": "bot-secret",
                "additional_key": "bot-additional",
                "success_url": "https://example.invalid/success",
                "fail_url": "https://example.invalid/fail",
                "webhook_path": "/api/billing/lava/webhook/bot",
            },
        }
        self.fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(self.fd)
        conn = sqlite3.connect(self.db)
        conn.execute("""
            CREATE TABLE invoices (
                invoice_id INTEGER PRIMARY KEY,
                telegram_id INTEGER,
                amount REAL,
                months REAL,
                days INTEGER,
                status TEXT,
                created_at TEXT,
                promo_code TEXT,
                bonus_days INTEGER DEFAULT 0,
                payment_provider TEXT DEFAULT 'cryptobot',
                provider_invoice_id TEXT,
                order_id TEXT
            )
        """)
        conn.commit()
        conn.close()
        self.old_db = bot_module.DB_PATH
        bot_module.DB_PATH = self.db

    def tearDown(self):
        bot_module.LAVA_STORE_CONFIG = self.old_config
        bot_module.DB_PATH = self.old_db
        try:
            os.unlink(self.db)
        except OSError:
            pass

    def test_webhook_signature_uses_store_additional_key(self):
        body = b'{"status":"paid","orderId":"order-1"}'
        signature = hmac.new(b"site-additional", body, hashlib.sha256).hexdigest()
        self.assertTrue(bot_module.verify_lava_webhook("site", body, signature))
        self.assertFalse(bot_module.verify_lava_webhook("site", body, "wrong"))
        bot_signature = hmac.new(b"bot-additional", body, hashlib.sha256).hexdigest()
        self.assertFalse(bot_module.verify_lava_webhook("site", body, bot_signature))

    def test_lava_invoice_lookup_and_atomic_claim(self):
        bot_module.save_lava_invoice(10001, "lava-provider-1", "mosaic-order-1", 42, 30, 30, "site")
        invoice = bot_module.get_lava_invoice(order_id="mosaic-order-1")
        self.assertEqual(invoice["telegram_id"], 42)
        self.assertEqual(invoice["days"], 30)
        self.assertEqual(invoice["store"], "site")
        self.assertEqual(bot_module.get_lava_invoice(provider_invoice_id="lava-provider-1")["invoice_id"], 10001)
        self.assertTrue(bot_module.update_invoice_status(10001, "paid"))
        self.assertFalse(bot_module.update_invoice_status(10001, "paid"))

    def test_store_configs_are_separate(self):
        self.assertNotEqual(bot_module.lava_store_config("site")["shop_id"], bot_module.lava_store_config("bot")["shop_id"])
        self.assertEqual(bot_module.lava_store_config("site")["webhook_path"], "/api/billing/lava/webhook/site")
        self.assertEqual(bot_module.lava_store_config("bot")["webhook_path"], "/api/billing/lava/webhook/bot")

    def test_new_invoice_restricts_checkout_to_sbp_and_cards(self):
        with mock.patch.object(
            bot_module,
            "_lava_signed_request",
            return_value={"id": "provider-1", "url": "https://pay.example.invalid/invoice"},
        ) as request:
            invoice = bot_module.create_lava_invoice("site", 42, 10, 10)
        payload = request.call_args.args[1]
        self.assertEqual(payload["includeService"], ["sbp", "card"])
        self.assertNotIn("lava_pay_in", payload["includeService"])
        self.assertEqual(invoice["payment_url"], "https://pay.example.invalid/invoice")


if __name__ == "__main__":
    unittest.main(verbosity=2)
