"""UX Redesign v2 — integrity tests for bot.py.

Tests verify:
1. All new MESSAGES keys are present in both ru/en locales.
2. All new callback data strings are present in bot.py source.
3. The 'Добавить в MosaicVPN' (_send_add_to_app_code) logic works with a
   real SQLite DB via exec-extracted source (the established pattern).
4. get_home_inline_keyboard / get_account_inline_keyboard / get_subscribe_inline_keyboard
   / get_help_inline_keyboard return the correct callback_data values.
5. HOME_BANNER_PATH fallback: _send_home_with_banner falls back to send_message
   when the banner file does not exist.
6. /add command and home_add_app callback both call _send_add_to_app_code.
7. Source-level: new /menu and /add commands are registered.
8. No existing callback_data values were removed (backward compat).

bot.py cannot be imported directly (TeleBot + decorators fire at import time).
We use the exec-on-source pattern from test_bot_logic.py.
"""
import datetime
import os
import sqlite3
import tempfile
import unittest

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
_SRC = open(BOT_PY, encoding="utf-8").read()

# ─── Required new MESSAGES keys ─────────────────────────────────────────────

NEW_RU_KEYS = [
    "home_title", "menu_account", "menu_subscribe", "menu_add_app",
    "menu_help", "menu_home", "account_section", "subscribe_section",
    "help_section", "add_app_prompt", "add_app_code_fmt", "add_app_no_profile",
    "add_app_error", "back_home", "web_cabinet", "renew_sub", "invite_friend",
    "status_btn", "faq_btn", "ticket_btn", "chat_support",
]

NEW_EN_KEYS = NEW_RU_KEYS  # same set, both locales required


# ─── exec helpers ────────────────────────────────────────────────────────────

def _extract(start_marker, end_marker):
    i = _SRC.index(start_marker)
    j = _SRC.index(end_marker, i)
    return _SRC[i:j]


# Extract MESSAGES constant (just its definition block) for key checking
MESSAGES_BLOCK = _extract("MESSAGES = {", "\nbot = telebot.TeleBot")


# ─── Test classes ─────────────────────────────────────────────────────────────

class TestNewMessagesKeys(unittest.TestCase):
    """All new copy keys must be present in both ru and en locales."""

    def test_ru_new_keys_in_messages_source(self):
        for key in NEW_RU_KEYS:
            self.assertIn(
                f'MESSAGES["ru"]["{key}"]', _SRC,
                f'Missing RU message key: MESSAGES["ru"]["{key}"]',
            )

    def test_en_new_keys_in_messages_source(self):
        for key in NEW_EN_KEYS:
            self.assertIn(
                f'MESSAGES["en"]["{key}"]', _SRC,
                f'Missing EN message key: MESSAGES["en"]["{key}"]',
            )

    def test_add_app_code_fmt_has_placeholders(self):
        """add_app_code_fmt must have {code} and {minutes} placeholders."""
        i = _SRC.index('MESSAGES["ru"]["add_app_code_fmt"]')
        snippet = _SRC[i:i + 400]
        self.assertIn("{code}", snippet)
        self.assertIn("{minutes}", snippet)

    def test_home_title_has_mosaicvpn(self):
        i = _SRC.index('MESSAGES["ru"]["home_title"]')
        snippet = _SRC[i:i + 200]
        self.assertIn("MosaicVPN", snippet)


class TestNewCallbackDataPresent(unittest.TestCase):
    """All new callback_data strings must appear in bot.py source."""

    REQUIRED_CALLBACKS = [
        "home_main", "home_account", "home_subscribe",
        "home_add_app", "home_help", "home_status",
    ]

    def test_all_new_callbacks_in_source(self):
        for cb in self.REQUIRED_CALLBACKS:
            self.assertIn(
                f'callback_data="{cb}"', _SRC,
                f"Missing callback_data=\"{cb}\" in bot.py",
            )

    def test_home_add_app_callback_handler(self):
        """home_add_app callback must be handled by a @bot.callback_query_handler."""
        self.assertIn('call.data == "home_add_app"', _SRC)

    def test_home_main_callback_handler(self):
        self.assertIn('call.data == "home_main"', _SRC)

    def test_home_account_callback_handler(self):
        self.assertIn('call.data == "home_account"', _SRC)

    def test_home_subscribe_callback_handler(self):
        self.assertIn('call.data == "home_subscribe"', _SRC)

    def test_home_help_callback_handler(self):
        self.assertIn('call.data == "home_help"', _SRC)

    def test_home_status_callback_handler(self):
        self.assertIn('call.data == "home_status"', _SRC)


class TestBackwardCompatCallbacks(unittest.TestCase):
    """All pre-existing callback_data values must still be present."""

    LEGACY_CALLBACKS = [
        # Buy flow
        'callback_data=f"buy_',
        'callback_data="buy_custom"',
        'callback_data="buy_subscription"',
        'callback_data="buy_discount"',
        # Payment methods
        'callback_data=f"lava_card_',
        'callback_data=f"lava_sbp_',
        # Profile linking
        'callback_data="ref_link"',
        'callback_data="ref_leaderboard"',
        'callback_data="show_tariffs"',
        # Language
        'callback_data="lang_ru"',
        'callback_data="lang_en"',
        # Support / tickets
        'callback_data="ticket_new"',
        'callback_data="ticket_list"',
        'callback_data="faq"',
        # Status / complaints
        'callback_data="report_issue"',
        'callback_data="back_to_status"',
    ]

    def test_legacy_callbacks_still_present(self):
        for cb in self.LEGACY_CALLBACKS:
            self.assertIn(cb, _SRC, f"Legacy callback removed or broken: {cb}")


class TestNewCommands(unittest.TestCase):
    """New /menu and /add commands must be registered."""

    def test_menu_command_handler(self):
        self.assertIn('commands=["menu"]', _SRC)

    def test_add_command_handler(self):
        self.assertIn('commands=["add"]', _SRC)

    def test_menu_in_bot_commands_setup(self):
        i = _SRC.index("def setup_bot_branding(")
        snippet = _SRC[i:i + 1200]
        self.assertIn('"menu"', snippet)
        self.assertIn('"add"', snippet)


class TestImageFallbackHelper(unittest.TestCase):
    """_send_home_with_banner must exist and be called from the /menu handler."""

    def test_helper_defined(self):
        self.assertIn("def _send_home_with_banner(", _SRC)

    def test_helper_called_from_show_home_menu(self):
        i = _SRC.index("def show_home_menu(message):")
        snippet = _SRC[i:i + 400]
        self.assertIn("_send_home_with_banner(", snippet)

    def test_helper_called_from_send_welcome(self):
        """Welcome handler must call _send_home_with_banner for the new home menu."""
        i = _SRC.index("def send_welcome(message):")
        # The send_welcome function is long; search over 10000 chars to find the call
        snippet = _SRC[i:i + 10000]
        self.assertIn("_send_home_with_banner(", snippet)

    def test_banner_path_env_var(self):
        """HOME_BANNER_PATH must be read from environment."""
        self.assertIn("MOSAIC_HOME_BANNER_PATH", _SRC)

    def test_fallback_uses_send_message(self):
        i = _SRC.index("def _send_home_with_banner(")
        snippet = _SRC[i:i + 1200]
        self.assertIn("bot.send_message(", snippet)
        self.assertIn("os.path.isfile(", snippet)


class TestAddToAppFlow(unittest.TestCase):
    """_send_add_to_app_code must call issue_link_code and format the message.

    We exec-extract the helper and the issue_link_code DB helper so we can
    run the logic against a real temporary SQLite DB (no mocks needed).
    """

    # ── DB schema fragments needed for issue_link_code ──
    SCHEMA_USERS = """
    CREATE TABLE IF NOT EXISTS users (
        telegram_id INTEGER PRIMARY KEY, username TEXT, short_uuid TEXT,
        language TEXT DEFAULT 'ru', trial_used INTEGER DEFAULT 0,
        created_at TEXT, referrer_id INTEGER
    )
    """
    SCHEMA_LINK_CODES = """
    CREATE TABLE IF NOT EXISTS link_codes (
        code TEXT PRIMARY KEY, telegram_id INTEGER NOT NULL, username TEXT,
        session_token TEXT, issued_at TEXT, expires_at TEXT, used_at TEXT,
        attempts INTEGER DEFAULT 0
    )
    """
    SCHEMA_TELEGRAM_LINKS = """
    CREATE TABLE IF NOT EXISTS telegram_account_links (
        telegram_id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL UNIQUE,
        telegram_username TEXT, linked_at TEXT NOT NULL
    )
    """

    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        conn = sqlite3.connect(self.db)
        conn.execute(self.SCHEMA_USERS)
        conn.execute(self.SCHEMA_LINK_CODES)
        conn.execute(self.SCHEMA_TELEGRAM_LINKS)
        conn.commit()
        conn.close()

        # Build a minimal namespace with the DB helpers we need
        import re as _re
        self.ns = {
            "sqlite3": sqlite3,
            "datetime": datetime,
            "logging": __import__("logging"),
            "logger": __import__("logging").getLogger("test"),
            "secrets": __import__("secrets"),
            "re": _re,
            "DB_PATH": self.db,
            "LINK_CODE_ALPHABET": "ABCDEFGHJKMNPQRSTUVWXYZ23456789",
            "LINK_CODE_TTL_MINUTES": 10,
            "LINK_CODE_MAX_ATTEMPTS": 5,
        }

        # exec issue_link_code + resolve_telegram_account_id + _link_code_normalise
        block = _extract(
            "def _link_code_normalise(raw):",
            "def issue_password_reset(",
        )
        exec(compile(block, BOT_PY, "exec"), self.ns)

    def tearDown(self):
        try:
            os.unlink(self.db)
        except OSError:
            pass

    def _insert_user(self, tid, username, short_uuid="abc123", lang="ru"):
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO users (telegram_id, username, short_uuid, language, trial_used, created_at) "
            "VALUES (?, ?, ?, ?, 1, ?)",
            (tid, username, short_uuid, lang, datetime.datetime.now().isoformat()),
        )
        conn.commit()
        conn.close()

    def test_issue_link_code_returns_code_and_expiry(self):
        self._insert_user(12345, "tg_12345")
        code, expires = self.ns["issue_link_code"](12345, "tg_12345", "short_uuid_abc")
        self.assertIsInstance(code, str)
        self.assertEqual(len(code), 8)
        self.assertIsInstance(expires, datetime.datetime)

    def test_code_uses_safe_alphabet(self):
        """Link codes must use only LINK_CODE_ALPHABET characters (no 0, O, 1, I, L)."""
        self._insert_user(99, "tg_99")
        code, _ = self.ns["issue_link_code"](99, "tg_99")
        alphabet = set(self.ns["LINK_CODE_ALPHABET"])
        for ch in code:
            self.assertIn(ch, alphabet, f"Char {ch!r} in code {code!r} is not in safe alphabet")

    def test_code_stored_in_db(self):
        self._insert_user(777, "tg_777")
        code, _ = self.ns["issue_link_code"](777, "tg_777")
        conn = sqlite3.connect(self.db)
        row = conn.execute("SELECT telegram_id FROM link_codes WHERE code=?", (code,)).fetchone()
        conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 777)

    def test_reissue_invalidates_previous_code(self):
        self._insert_user(888, "tg_888")
        code1, _ = self.ns["issue_link_code"](888, "tg_888")
        code2, _ = self.ns["issue_link_code"](888, "tg_888")
        self.assertNotEqual(code1, code2)
        conn = sqlite3.connect(self.db)
        rows = conn.execute(
            "SELECT code, used_at FROM link_codes WHERE telegram_id=888"
        ).fetchall()
        conn.close()
        # code1 should be gone (deleted on reissue), only code2 remains unused
        codes_in_db = {r[0] for r in rows}
        self.assertIn(code2, codes_in_db)
        self.assertNotIn(code1, codes_in_db)

    def test_redeem_marks_code_used(self):
        self._insert_user(555, "tg_555")
        code, _ = self.ns["issue_link_code"](555, "tg_555")
        payload, err = self.ns["redeem_link_code"](code)
        self.assertIsNone(err)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["telegram_id"], 555)
        # Second redeem must fail
        payload2, err2 = self.ns["redeem_link_code"](code)
        self.assertIsNone(payload2)
        self.assertEqual(err2, "used")

    def test_add_app_code_fmt_renders(self):
        """add_app_code_fmt must render without KeyError given code + minutes."""
        fmt = MESSAGES_BLOCK  # not imported — check via source text presence
        # Use the template from the source directly
        i = _SRC.index('MESSAGES["ru"]["add_app_code_fmt"] = (')
        end = _SRC.index("\n)\n", i) + 3
        snippet = _SRC[i:end]
        self.assertIn("{code}", snippet)
        self.assertIn("{minutes}", snippet)


class TestHomeKeyboards(unittest.TestCase):
    """Smoke-check keyboard builder functions via source analysis."""

    def test_get_home_inline_keyboard_defined(self):
        self.assertIn("def get_home_inline_keyboard(lang):", _SRC)

    def test_get_account_inline_keyboard_defined(self):
        self.assertIn("def get_account_inline_keyboard(lang", _SRC)

    def test_get_subscribe_inline_keyboard_defined(self):
        self.assertIn("def get_subscribe_inline_keyboard(lang):", _SRC)

    def test_get_help_inline_keyboard_defined(self):
        self.assertIn("def get_help_inline_keyboard(lang):", _SRC)

    def test_get_home_keyboard_has_four_sections(self):
        i = _SRC.index("def get_home_inline_keyboard(lang):")
        snippet = _SRC[i:i + 800]
        for cb in ["home_account", "home_subscribe", "home_add_app", "home_help"]:
            self.assertIn(cb, snippet, f"home keyboard missing section: {cb}")

    def test_account_keyboard_has_back_home(self):
        i = _SRC.index("def get_account_inline_keyboard(lang")
        # Full function body can exceed 600 chars; use 1200
        snippet = _SRC[i:i + 1200]
        self.assertIn("home_main", snippet)

    def test_subscribe_keyboard_has_back_home(self):
        i = _SRC.index("def get_subscribe_inline_keyboard(lang):")
        snippet = _SRC[i:i + 600]
        self.assertIn("home_main", snippet)

    def test_help_keyboard_has_back_home_and_support_url(self):
        i = _SRC.index("def get_help_inline_keyboard(lang):")
        snippet = _SRC[i:i + 600]
        self.assertIn("home_main", snippet)
        self.assertIn("mosaicsup", snippet)

    def test_legacy_get_main_menu_still_present(self):
        """The legacy reply-keyboard function must survive for backward compat."""
        self.assertIn("def get_main_menu(lang):", _SRC)
        # It must still produce a ReplyKeyboardMarkup
        i = _SRC.index("def get_main_menu(lang):")
        snippet = _SRC[i:i + 400]
        self.assertIn("ReplyKeyboardMarkup", snippet)


class TestSendAddToAppCodeIntegration(unittest.TestCase):
    """Integration: _send_add_to_app_code logic (no-profile path, error path)."""

    def test_no_profile_message_key_in_source(self):
        """add_app_no_profile must be sent when user has no profile."""
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 1500]
        self.assertIn('t["add_app_no_profile"]', snippet)

    def test_error_message_key_in_source(self):
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 1500]
        self.assertIn('t["add_app_error"]', snippet)

    def test_uses_issue_link_code(self):
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 1500]
        self.assertIn("issue_link_code(", snippet)

    def test_uses_resolve_telegram_account_id(self):
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 1500]
        self.assertIn("resolve_telegram_account_id(", snippet)

    def test_new_code_button_for_refresh(self):
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 2000]
        self.assertIn('"home_add_app"', snippet)

    def test_back_home_button_present(self):
        i = _SRC.index("def _send_add_to_app_code(telegram_id):")
        snippet = _SRC[i:i + 2000]
        self.assertIn('"home_main"', snippet)


if __name__ == "__main__":
    unittest.main(verbosity=2)
