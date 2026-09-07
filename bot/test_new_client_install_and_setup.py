import unittest
import urllib.parse
from bot import bot as bot_module
from telebot import types

class TestNewClientInstallAndSetup(unittest.TestCase):
    def test_home_inline_keyboard_has_new_buttons(self):
        markup = bot_module.get_home_inline_keyboard("ru")
        self.assertIsInstance(markup, types.InlineKeyboardMarkup)
        callbacks = [btn.callback_data for row in markup.keyboard for btn in row if btn.callback_data]
        self.assertIn("home_install", callbacks)
        self.assertIn("home_add_client_menu", callbacks)
        self.assertIn("home_account", callbacks)
        self.assertIn("home_subscribe", callbacks)
        self.assertIn("ref_link", callbacks)
        self.assertIn("home_help", callbacks)

    def test_install_keyboards_all_platforms(self):
        os_markup = bot_module.get_install_os_keyboard("ru")
        os_callbacks = [btn.callback_data for row in os_markup.keyboard for btn in row if btn.callback_data]
        self.assertIn("install_android", os_callbacks)
        self.assertIn("install_windows", os_callbacks)
        self.assertIn("install_linux", os_callbacks)
        self.assertIn("home_main", os_callbacks)

        # Android
        android_markup = bot_module.get_install_android_keyboard("ru")
        android_urls = [btn.url for row in android_markup.keyboard for btn in row if btn.url]
        self.assertTrue(any("apk" in url.lower() for url in android_urls))

        # Windows
        windows_markup = bot_module.get_install_windows_keyboard("ru")
        windows_urls = [btn.url for row in windows_markup.keyboard for btn in row if btn.url]
        self.assertTrue(any(".exe" in url.lower() for url in windows_urls))
        self.assertTrue(any(".zip" in url.lower() for url in windows_urls))

        # Linux
        linux_markup = bot_module.get_install_linux_keyboard("ru")
        linux_urls = [btn.url for row in linux_markup.keyboard for btn in row if btn.url]
        self.assertTrue(any(".deb" in url.lower() for url in linux_urls))
        self.assertTrue(any(".tar.gz" in url.lower() for url in linux_urls))

    def test_add_client_menu_with_personalized_sub_url(self):
        sub_url = "https://sub.zxc1x1.ru/mysecretkey123"
        markup = bot_module.get_add_client_inline_keyboard("ru", sub_url=sub_url)
        
        # Check Mosaic official button
        callbacks = [btn.callback_data for row in markup.keyboard for btn in row if btn.callback_data]
        self.assertIn("home_add_app", callbacks)

        # Check Third-party button has direct personalized URL
        urls = [btn.url for row in markup.keyboard for btn in row if btn.url]
        self.assertTrue(any("manual.html" in url for url in urls))
        manual_btn_url = [url for url in urls if "manual.html" in url][0]
        self.assertIn("sub=", manual_btn_url)
        self.assertIn("mysecretkey123", manual_btn_url)

    def test_account_keyboard_web_cabinet_parity(self):
        sub_url = "https://sub.zxc1x1.ru/testuuid"
        # When active
        markup_active = bot_module.get_account_inline_keyboard("ru", sub_url=sub_url, is_frozen=False)
        callbacks_active = [btn.callback_data for row in markup_active.keyboard for btn in row if btn.callback_data]
        self.assertIn("home_account_freeze", callbacks_active)
        self.assertIn("home_account_rotate_ask", callbacks_active)
        self.assertIn("home_install", callbacks_active)
        self.assertIn("home_add_client_menu", callbacks_active)

        # When frozen
        markup_frozen = bot_module.get_account_inline_keyboard("ru", sub_url=sub_url, is_frozen=True)
        callbacks_frozen = [btn.callback_data for row in markup_frozen.keyboard for btn in row if btn.callback_data]
        self.assertIn("home_account_unfreeze", callbacks_frozen)

if __name__ == "__main__":
    unittest.main()
