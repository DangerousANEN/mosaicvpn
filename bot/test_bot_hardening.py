"""Targeted unit tests for bot-only legal hardening, terms gating, and schema consistency.

Developer-sandbox safe:
- Dummy credentials only.
- In-memory / temporary isolated SQLite databases.
- Telebot / Telegram API and payment provider HTTP calls completely mocked.
"""
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Ensure isolated dummy credentials before importing bot module
os.environ["MOSAIC_BOT_TOKEN"] = "123456:TEST_BOT_TOKEN_DUMMY"
os.environ["MOSAIC_REMNAWAVE_TOKEN"] = "TEST_REMNAWAVE_TOKEN_DUMMY"
os.environ["MOSAIC_LEGAL_TERMS_VERSION"] = "1.0"

import tempfile
import sqlite3

# Import target bot module
from bot import bot as bot_module


class BaseHardeningTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.temp_db.close()
        self.db_path = self.temp_db.name
        self.orig_db_path = bot_module.DB_PATH
        bot_module.DB_PATH = self.db_path

        # Initialize schema in clean temporary database
        bot_module.init_db()

    def tearDown(self):
        bot_module.DB_PATH = self.orig_db_path
        if os.path.exists(self.db_path):
            try:
                os.remove(self.db_path)
            except OSError:
                pass


class TestDatabaseAndSchemaHardening(BaseHardeningTestCase):
    """Test schema consistency: terms_accepted_version vs terms_version."""

    def test_schema_has_terms_columns_on_users_and_invoices(self):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute("PRAGMA table_info(users)")
        user_cols = {row[1] for row in cursor.fetchall()}
        self.assertIn("terms_accepted_version", user_cols)
        self.assertIn("terms_accepted_at", user_cols)

        cursor.execute("PRAGMA table_info(invoices)")
        inv_cols = {row[1] for row in cursor.fetchall()}
        self.assertIn("terms_version", inv_cols)
        conn.close()

    def test_get_user_retrieves_terms_accepted_version_without_error(self):
        tg_id = 99887711
        bot_module.save_user(tg_id, "test_user", "short-uuid-1")

        # Initially no terms accepted
        u = bot_module.get_user(tg_id)
        self.assertIsNotNone(u)
        self.assertIsNone(u.get("terms_accepted_version"))
        self.assertIsNone(u.get("terms_version"))

        # Explicitly accept terms
        bot_module.record_terms_acceptance(tg_id, "1.0", source="bot")
        u2 = bot_module.get_user(tg_id)
        self.assertIsNotNone(u2)
        self.assertEqual(u2.get("terms_accepted_version"), "1.0")
        self.assertEqual(u2.get("terms_version"), "1.0")
        self.assertIsNotNone(u2.get("terms_accepted_at"))

    def test_versioned_acceptance_helpers(self):
        tg_id = 11223344
        bot_module.save_user(tg_id, "version_user", "short-uuid-2")

        self.assertFalse(bot_module.has_user_accepted_terms(tg_id, "1.0"))
        self.assertFalse(bot_module.has_user_accepted_terms(tg_id, "2.0"))

        bot_module.record_terms_acceptance(tg_id, "1.0", source="bot")
        self.assertTrue(bot_module.has_user_accepted_terms(tg_id, "1.0"))
        self.assertFalse(bot_module.has_user_accepted_terms(tg_id, "2.0"))

        # Check terms_acceptances audit table
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT version, source FROM terms_acceptances WHERE telegram_id = ?", (tg_id,))
        records = cursor.fetchall()
        self.assertEqual(records, [("1.0", "bot")])
        conn.close()


class TestPaymentGatingAndTermsFlow(BaseHardeningTestCase):
    """Test callback gating on purchase routes and legal prompt integration."""

    def test_handle_buy_callback_unaccepted_terms_triggers_prompt(self):
        tg_id = 55443322
        bot_module.save_user(tg_id, "buyer1", "uuid-buyer1")

        call = MagicMock()
        call.id = "call_123"
        call.data = "buy_30"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "send_terms_prompt") as mock_prompt, \
             patch.object(bot_module, "_send_lava_payment_method_menu") as mock_menu:
            bot_module.handle_buy_callback(call)
            mock_answer.assert_called_once_with("call_123")
            mock_prompt.assert_called_once_with(tg_id, "ru", action="buy_30")
            mock_menu.assert_not_called()

    def test_handle_buy_callback_accepted_terms_proceeds_to_menu(self):
        tg_id = 55443323
        bot_module.save_user(tg_id, "buyer2", "uuid-buyer2")
        bot_module.record_terms_acceptance(tg_id, "1.0", source="bot")

        call = MagicMock()
        call.id = "call_124"
        call.data = "buy_30"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "send_terms_prompt") as mock_prompt, \
             patch.object(bot_module, "_send_lava_payment_method_menu") as mock_menu:
            bot_module.handle_buy_callback(call)
            mock_answer.assert_called_once_with("call_124")
            mock_prompt.assert_not_called()
            mock_menu.assert_called_once_with(tg_id, bot_module.PACKAGES[30]["price_rub"], 30, "ru")

    def test_handle_buy_discount_callback_gated_by_terms(self):
        tg_id = 55443324
        bot_module.save_user(tg_id, "buyer3", "uuid-buyer3")

        call = MagicMock()
        call.id = "call_125"
        call.data = "buy_discount_30"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "send_terms_prompt") as mock_prompt, \
             patch.object(bot_module, "create_cryptopay_invoice") as mock_crypto:
            bot_module.handle_buy_discount_callback(call)
            mock_prompt.assert_called_once_with(tg_id, "ru", action="buy_discount_30")
            mock_crypto.assert_not_called()

    def test_handle_lava_payment_method_callback_gated_by_terms(self):
        tg_id = 55443325
        bot_module.save_user(tg_id, "buyer4", "uuid-buyer4")

        call = MagicMock()
        call.id = "call_126"
        call.data = "lava_card_300_30"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "send_terms_prompt") as mock_prompt, \
             patch.object(bot_module, "_send_lava_invoice_for_chat") as mock_send_inv:
            bot_module.handle_lava_payment_method_callback(call)
            mock_prompt.assert_called_once_with(tg_id, "ru", action="lava_card_300_30")
            mock_send_inv.assert_not_called()

    def test_handle_buy_custom_callback_gated_by_terms(self):
        tg_id = 55443326
        bot_module.save_user(tg_id, "buyer5", "uuid-buyer5")

        call = MagicMock()
        call.id = "call_127"
        call.data = "buy_custom"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "send_terms_prompt") as mock_prompt, \
             patch.object(bot_module.bot, "register_next_step_handler") as mock_next:
            bot_module.handle_buy_custom_callback(call)
            mock_prompt.assert_called_once_with(tg_id, "ru", action="buy_custom")
            mock_next.assert_not_called()

    def test_accept_terms_callback_records_acceptance_and_resumes_action(self):
        tg_id = 55443327
        bot_module.save_user(tg_id, "buyer6", "uuid-buyer6")
        self.assertFalse(bot_module.has_user_accepted_terms(tg_id, "1.0"))

        call = MagicMock()
        call.id = "call_128"
        call.data = "accept_terms:buy_30"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "_send_lava_payment_method_menu") as mock_menu:
            bot_module.handle_accept_terms_callback(call)
            self.assertTrue(bot_module.has_user_accepted_terms(tg_id, "1.0"))
            mock_menu.assert_called_once_with(tg_id, bot_module.PACKAGES[30]["price_rub"], 30, "ru")

    def test_terms_decline_callback_answers_and_sends_warning(self):
        tg_id = 55443328
        bot_module.save_user(tg_id, "buyer7", "uuid-buyer7")

        call = MagicMock()
        call.id = "call_129"
        call.data = "terms_decline"
        call.message.chat.id = tg_id

        with patch.object(bot_module.bot, "answer_callback_query") as mock_answer, \
             patch.object(bot_module, "_safe_bot_send_message") as mock_send:
            bot_module.handle_terms_decline_callback(call)
            mock_answer.assert_called_once()
            mock_send.assert_called_once()
            self.assertIn("необходимо принять", mock_send.call_args[0][1])


class TestLegalCommandsAndInformation(BaseHardeningTestCase):
    """Test /terms, /paysupport, show_terms, show_paysupport."""

    def test_terms_command_shows_not_accepted_for_new_user(self):
        tg_id = 77112233
        bot_module.save_user(tg_id, "legal_user", "uuid-legal")

        msg = MagicMock()
        msg.chat.id = tg_id

        with patch.object(bot_module, "_safe_bot_send_message") as mock_send:
            bot_module.handle_terms_command(msg)
            mock_send.assert_called_once()
            text = mock_send.call_args[0][1]
            self.assertIn("Не приняты", text)

    def test_terms_command_shows_accepted_after_acceptance(self):
        tg_id = 77112234
        bot_module.save_user(tg_id, "legal_user2", "uuid-legal2")
        bot_module.record_terms_acceptance(tg_id, "1.0")

        msg = MagicMock()
        msg.chat.id = tg_id

        with patch.object(bot_module, "_safe_bot_send_message") as mock_send:
            bot_module.handle_terms_command(msg)
            mock_send.assert_called_once()
            text = mock_send.call_args[0][1]
            self.assertIn("Приняты", text)

    def test_paysupport_command_sends_paysupport_text_and_markup(self):
        tg_id = 77112235
        bot_module.save_user(tg_id, "legal_user3", "uuid-legal3")

        msg = MagicMock()
        msg.chat.id = tg_id

        with patch.object(bot_module, "_safe_bot_send_message") as mock_send:
            bot_module.handle_paysupport_command(msg)
            mock_send.assert_called_once()
            reply_markup = mock_send.call_args[1]["reply_markup"]
            self.assertIsInstance(reply_markup, bot_module.types.InlineKeyboardMarkup)


class TestPaymentIdempotencyAndRateLimiting(BaseHardeningTestCase):
    """Verify payment idempotency and anti-spam rate limiting behavior."""

    def test_save_invoice_and_lava_invoice_record_terms_version(self):
        tg_id = 88223311
        bot_module.save_user(tg_id, "inv_user", "uuid-inv")

        bot_module.save_invoice(12345678, tg_id, 100, 1, 30, terms_version="1.0")
        bot_module.save_lava_invoice(87654321, "prov_1", "ord_1", tg_id, 150, 30, "bot", terms_version="1.0")

        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute("SELECT terms_version FROM invoices WHERE invoice_id = 12345678")
        self.assertEqual(c.fetchone()[0], "1.0")

        c.execute("SELECT terms_version FROM invoices WHERE invoice_id = 87654321")
        self.assertEqual(c.fetchone()[0], "1.0")
        conn.close()

    def test_rate_limit_check_enforces_buy_limit(self):
        tg_id = 88223322
        # Max limit for "buy" is 10 within 60 seconds
        for _ in range(10):
            allowed = bot_module.rate_limit_check(tg_id, "buy")
            self.assertTrue(allowed)

        # 11th request within same minute should be blocked
        blocked = bot_module.rate_limit_check(tg_id, "buy")
        self.assertFalse(blocked)


if __name__ == "__main__":
    unittest.main()
