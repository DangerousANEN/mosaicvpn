"""Regression tests for tariff text and Telegram purchase entry points."""
from pathlib import Path
import unittest

SOURCE = Path(__file__).with_name("bot.py").read_text(encoding="utf-8")


class TariffUITest(unittest.TestCase):
    def test_legacy_tariff_code_block_is_gone(self):
        start = SOURCE.index('"tariffs": (')
        end = SOURCE.index('"instructions": (', start)
        tariff_block = SOURCE[start:end]
        self.assertNotIn('"```', tariff_block)
        self.assertIn("Своя сумма", tariff_block)
        en_start = SOURCE.index('"tariffs": (', start + 1)
        en_end = SOURCE.index('"instructions": (', en_start)
        self.assertIn("Custom amount", SOURCE[en_start:en_end])

    def test_reply_keyboard_buy_uses_shared_menu(self):
        start = SOURCE.index('def buy_subscription_menu(')
        end = SOURCE.index('@bot.message_handler(commands=["profile"])', start)
        block = SOURCE[start:end]
        self.assertIn("send_buy_menu(telegram_id, lang)", block)
        self.assertNotIn('for days, pkg in PACKAGES.items()', block)

    def test_custom_button_exists_in_both_purchase_entry_points(self):
        self.assertGreaterEqual(SOURCE.count('callback_data="buy_custom"'), 2)
        self.assertIn('def process_custom_lava_amount(message):', SOURCE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
