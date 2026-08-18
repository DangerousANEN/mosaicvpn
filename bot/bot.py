import telebot
from telebot import types
import requests
import sqlite3
import threading
import time
import os
import datetime
from datetime import timezone
from zoneinfo import ZoneInfo
import dateutil.parser
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import urllib.parse
import socks
import concurrent.futures
import psycopg2
import base64
import secrets
import hashlib
import hmac

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# Tokens
BOT_TOKEN = os.environ.get("MOSAIC_BOT_TOKEN", "")
CRYPTO_PAY_TOKEN = os.environ.get("MOSAIC_CRYPTO_PAY_TOKEN", "")

# Lava Business API: separate stores for Telegram and web checkout.
# Secrets are read only from the VPS environment; never put them in source or frontend.
LAVA_API_BASE = os.environ.get("MOSAIC_LAVA_API_BASE", "https://api.lava.ru/business").rstrip("/")
LAVA_SITE_SHOP_ID = os.environ.get("MOSAIC_LAVA_SITE_SHOP_ID", "")
LAVA_SITE_SECRET_KEY = os.environ.get("MOSAIC_LAVA_SITE_SECRET_KEY", "")
LAVA_SITE_ADDITIONAL_KEY = os.environ.get("MOSAIC_LAVA_SITE_ADDITIONAL_KEY", "")
LAVA_BOT_SHOP_ID = os.environ.get("MOSAIC_LAVA_BOT_SHOP_ID", "")
LAVA_BOT_SECRET_KEY = os.environ.get("MOSAIC_LAVA_BOT_SECRET_KEY", "")
LAVA_BOT_ADDITIONAL_KEY = os.environ.get("MOSAIC_LAVA_BOT_ADDITIONAL_KEY", "")
LAVA_SITE_SUCCESS_URL = os.environ.get("MOSAIC_LAVA_SITE_SUCCESS_URL", "https://sub.zxc1x1.ru/cabinet.html?payment=success")
LAVA_SITE_FAIL_URL = os.environ.get("MOSAIC_LAVA_SITE_FAIL_URL", "https://sub.zxc1x1.ru/cabinet.html?payment=failed")
LAVA_BOT_SUCCESS_URL = os.environ.get("MOSAIC_LAVA_BOT_SUCCESS_URL", LAVA_SITE_SUCCESS_URL)
LAVA_BOT_FAIL_URL = os.environ.get("MOSAIC_LAVA_BOT_FAIL_URL", LAVA_SITE_FAIL_URL)
# New invoices must offer consumer methods only. Do not send MosaicVPN
# customers to the internal Lava wallet sign-in page. Lava returns exact active
# service IDs per shop (for example, `card_ru`), so this is an allow-list rather
# than an unconditional payload sent to every invoice.
LAVA_CONSUMER_SERVICES = frozenset(
    item.strip().lower()
    for item in os.environ.get(
        "MOSAIC_LAVA_PAYMENT_SERVICES",
        "sbp,card,card_ru,mir_card,mir_pay,sber_pay",
    ).split(",")
    if item.strip()
)
LAVA_WEBHOOK_SITE_PATH = "/api/billing/lava/webhook/site"
LAVA_WEBHOOK_BOT_PATH = "/api/billing/lava/webhook/bot"

# API Helpers (direct calls to Remnawave localhost)
API_TOKEN = os.environ.get("MOSAIC_REMNAWAVE_TOKEN", "")
# Remnawave refuses direct plain-HTTP calls (ProxyCheckMiddleware: "Reverse
# proxy and HTTPS are required"), so every request must go through nginx.
BASE_URL = os.environ.get("MOSAIC_REMNAWAVE_URL", "https://panel.zxc1x1.ru")
SQUAD_UUID = "7eea96e4-e8f1-4340-ab81-234fd8a24a85" # Default-Squad

# Credentials come from the environment only; never commit real keys.
_missing = [n for n, v in (("MOSAIC_BOT_TOKEN", BOT_TOKEN),
                            ("MOSAIC_REMNAWAVE_TOKEN", API_TOKEN)) if not v]
if _missing:
    raise SystemExit("missing required environment variables: " + ", ".join(_missing))

DB_PATH = "/opt/mosaic-bot/bot.db"
ADMIN_FILE = "/opt/mosaic-bot/admins.txt"

# Telegram IDs allowed to use /admin, receive alerts, and see forwarded complaints.
# Split on comma to allow multiple admins. The first registered user (owner) is
# the default fallback so admin alerts work even before the env var is set.
_raw_admins = os.environ.get("MOSAIC_ADMIN_IDS", "")
ADMIN_IDS = set()
if _raw_admins:
    for _id in _raw_admins.replace(";", ",").split(","):
        _id = _id.strip()
        if _id.isdigit():
            ADMIN_IDS.add(int(_id))
if not ADMIN_IDS:
    # Owner is always an admin unless explicitly overridden.
    ADMIN_IDS = {831992162}

# Pricing Packages (1 RUB = 1 day)
# Min 10 days = 10 RUB (0.10 USDT), Max 90 days = 90 RUB (0.90 USDT)
PACKAGES = {
    10: {"months": 10 / 30.0, "price_rub": 10, "price_usdt": 0.10, "ru": "10 дней — 10 ₽", "en": "10 days — 10 RUB"},
    30: {"months": 1.0, "price_rub": 30, "price_usdt": 0.30, "ru": "30 дней — 30 ₽", "en": "30 days — 30 RUB"},
}

# Bot Messages Dictionary
MESSAGES = {
    "ru": {
        "welcome": (
            "🛡 **Mosaic vpn.** — Атлас свободных маршрутов\n\n"
            "Никаких блокировок YouTube, Instagram и любимых сайтов. "
            "Протокол **VLESS xHTTP** маскирует трафик под обычные веб-страницы — заблокировать невозможно.\n\n"
            "✅ Ваш маршрут открыт: **3 дня тест-драйва** зачислены, подписка активна.\n\n"
            "```\n"
            " TARIFF · 1 RUB = 1 DAY\n"
            " DEVICES · 5 (HWID CONTROL)\n"
            " LATENCY · LOW · SPEED · HIGH\n"
            "```\n"
            "\n"
            "Перейдите в **📖 Инструкция** для установки за 1 минуту."
        ),
        "menu_buy": "🛒 Купить подписку",
        "menu_profile": "👤 Мой профиль",
        "menu_tariffs": "💎 Тарифы",
        "menu_instructions": "📖 Инструкция",
        "menu_lang": "🌐 Язык / Language",
        "buy_title": "🛒 Выберите пакет пополнения (1 рубль = 1 день):",
        "pay_title": "💳 **Счёт готов**\n\n```\n ITEM  · {days} DAYS TOP-UP\n AMOUNT · {amount:.2f} USDT\n```\n\nНажмите кнопку ниже для оплаты через CryptoBot.",
        "pay_button": "💳 Оплатить через CryptoBot",
        "lava_button": "🏦 Оплатить через СБП / карту",
        "custom_button": "✍️ Своя сумма",
        "p2p_info": (
            "\n\n*💳 Как оплатить картой РФ / СБП без криптовалюты?*\n"
            "1. Перейдите в @CryptoBot -> Маркет (P2P).\n"
            "2. Купите необходимое количество USDT за рубли через СБП / карту банка в 2 клика.\n"
            "3. Оплатите выданный ботом счет в один клик с вашего баланса CryptoBot!"
        ),
        "profile_active": (
            "👤 **Ваш Профиль**\n\n"
            "```\n"
            " USER     · {username}\n"
            " STATUS   · АКТИВЕН\n"
            " BALANCE  · {balance} RUB\n"
            " REMAINING· {days} ДНЕЙ (ДО {expire_date})\n"
            " HWID     · 5 УСТРОЙСТВ\n"
            "```\n\n"
            "🔗 **Ваша ссылка на подписку (Атлас):**\n"
            "`{sub_url}`\n\n"
            "Скопируйте ссылку или откройте веб-карту для настройки приложений."
        ),
        "profile_inactive": (
            "👤 **Ваш Профиль**\n\n"
            "```\n"
            " USER     · {username}\n"
            " STATUS   · ПРОСРОЧЕН\n"
            " BALANCE  · 0 RUB\n"
            " EXPIRES  · {expire_date}\n"
            "```\n\n"
            "Пополните баланс для восстановления доступа."
        ),
        "profile_not_found": "⚠️ Профиль не найден. Нажмите **🛒 Купить подписку** для создания.",
        "tariffs": (
            "💎 **Тарифы и правила**\n\n"
            "Стоимость доступа: **1 ₽ = 1 день**.\n"
            "В стоимость уже включены маршруты и поддержка — дополнительных комиссий MosaicVPN нет.\n\n"
            "• **10 дней — 10 ₽**\n"
            "• **30 дней — 30 ₽**\n"
            "• **Своя сумма — от 1 ₽**\n\n"
            "После оплаты дни добавляются к вашему действующему сроку. Выберите готовый тариф или укажите произвольную сумму ниже.\n\n"
            "💬 Поддержка: @mosaicsup"
        ),
        "instructions": (
            "📖 **Настройка за 1 минуту**\n\n"
            "1. Откройте **веб-карту** (кнопка 🗺 Веб-карта в меню).\n"
            "2. Перейдите во вкладку **«Программы»** (Software) в меню слева.\n"
            "3. Выберите устройство (iOS, Android, Windows, macOS, Linux) и установите клиент.\n"
            "4. Нажмите **«ИМПОРТИРОВАТЬ В MOSAICVPN»** (или вставьте ссылку в приложение).\n\n"
            "✅ Подписка добавится автоматически.\n\n"
            "💬 Поддержка: @mosaicsup"
        ),
        "payment_success": (
            "✅ **Оплата зачислена**\n\n"
            "```\n"
            " TOP-UP    · {days} RUB\n"
            " EXTENDED  · {days} DAYS\n"
            " VALID TO  · {expire_date}\n"
            "```\n\n"
            "🔗 Ссылка на подписку:\n"
            "`{sub_url}`"
        ),
        "lang_title": "🌐 Выберите язык / Select language:",
        "lang_success": "✅ Язык изменён на Русский.",
        "error_invoice": "⚠️ Ошибка при создании счёта. Попробуйте позже.",
        "broadcast_sent": "📢 Рассылка отправлена {count} пользователям.",
        "support": (
            "💬 **Поддержка Mosaic vpn.**\n\n"
            "Вопросы по оплате, настройке или работе сервиса:\n"
            "💬 @mosaicsup\n\n"
            "Мы ответим в самое ближайшее время\\!"
        )
    },
    "en": {
        "welcome": (
            "🛡 **Mosaic vpn.** — Atlas of Secure Routes\n\n"
            "Bypass censorship of YouTube, Instagram and other blocked sites. "
            "Our **VLESS xHTTP** protocol disguises traffic as ordinary web pages — unblockable by design.\n\n"
            "✅ Your route is open: **3-day free trial** activated, subscription is live.\n\n"
            "```\n"
            " TARIFF · 1 RUB = 1 DAY\n"
            " DEVICES · 5 (HWID CONTROL)\n"
            " LATENCY · LOW · SPEED · HIGH\n"
            "```\n"
            "\n"
            "Open **📖 Setup Instructions** to configure in 1 minute."
        ),
        "menu_buy": "🛒 Buy subscription",
        "menu_profile": "👤 Profile",
        "menu_tariffs": "💎 Tariffs",
        "menu_instructions": "📖 Setup",
        "menu_lang": "🌐 Language / Язык",
        "buy_title": "🛒 Select a top-up package (1 RUB = 1 day):",
        "pay_title": "💳 **Invoice ready**\n\n```\n ITEM  · {days} DAYS TOP-UP\n AMOUNT · {amount:.2f} USDT\n```\n\nClick the button below to pay via CryptoBot.",
        "pay_button": "💳 Pay via CryptoBot",
        "lava_button": "🏦 Pay by SBP / card",
        "custom_button": "✍️ Custom amount",
        "p2p_info": (
            "\n\n*💳 How to pay with RU card / SBP without crypto?*\n"
            "1. Open @CryptoBot → Market (P2P).\n"
            "2. Buy USDT for rubles via SBP / bank card in 2 clicks.\n"
            "3. Pay the invoice in one click from your CryptoBot balance!"
        ),
        "profile_active": (
            "👤 **Profile**\n\n"
            "```\n"
            " USER     · {username}\n"
            " STATUS   · ACTIVE\n"
            " BALANCE  · {balance} RUB\n"
            " REMAINING· {days} DAYS (TO {expire_date})\n"
            " HWID     · 5 DEVICES\n"
            "```\n\n"
            "🔗 **Subscription link:**\n"
            "`{sub_url}`\n\n"
            "Copy this link or open the web map to manage subscription and setup apps."
        ),
        "profile_inactive": (
            "👤 **Profile**\n\n"
            "```\n"
            " USER     · {username}\n"
            " STATUS   · EXPIRED\n"
            " BALANCE  · 0 RUB\n"
            " EXPIRES  · {expire_date}\n"
            "```\n\n"
            "Please top up your balance to restore access."
        ),
        "profile_not_found": "⚠️ Profile not found. Click **🛒 Buy subscription** to create one.",
        "tariffs": (
            "💎 **Tariffs and Rules**\n\n"
            "Access costs **1 RUB = 1 day**.\n"
            "Routes and support are included; MosaicVPN adds no extra service fee.\n\n"
            "• **10 days — 10 RUB**\n"
            "• **30 days — 30 RUB**\n"
            "• **Custom amount — from 1 RUB**\n\n"
            "After payment, the days are added to your current access period. Choose a package or enter any amount below.\n\n"
            "💬 Support: @mosaicsup"
        ),
        "instructions": (
            "📖 **Simple 1-minute Setup**\n\n"
            "1. Open the **web map** (click 🗺 Web Map in menu).\n"
            "2. Go to the **\"Software\"** tab in the left-hand menu.\n"
            "3. Choose your device (iOS, Android, Windows, macOS, Linux) and install the client.\n"
            "4. Click **\"IMPORT TO MOSAIC\"** (or paste the link into the app).\n\n"
            "✅ The subscription will be added automatically.\n\n"
            "💬 Support: @mosaicsup"
        ),
        "payment_success": (
            "✅ **Payment received**\n\n"
            "```\n"
            " TOP-UP    · {days} RUB\n"
            " EXTENDED  · {days} DAYS\n"
            " VALID TO  · {expire_date}\n"
            "```\n\n"
            "🔗 Subscription link:\n"
            "`{sub_url}`"
        ),
        "lang_title": "🌐 Select language / Выберите язык:",
        "lang_success": "✅ Language changed to English.",
        "error_invoice": "⚠️ Failed to create invoice. Please try again later.",
        "broadcast_sent": "📢 Broadcast sent to {count} users.",
        "support": (
            "💬 **Mosaic vpn. Support**\n\n"
            "Questions about payments, configuration, or service:\n"
            "💬 @mosaicsup\n\n"
            "We will get back to you as soon as possible!"
        )
    }
}

# Inject new messages for Free Proxies
MESSAGES["ru"]["menu_proxies"] = "⚡ Бесплатные прокси"
MESSAGES["ru"]["proxies_welcome"] = "⚡ **Бесплатные MTProto и SOCKS5 прокси**\n\nАвтоматически проверяемые прокси, устойчивые к блокировкам DPI.\n\nВыберите категорию ниже:"
MESSAGES["ru"]["proxies_loading"] = "⏳ Загружаю актуальные прокси..."
MESSAGES["ru"]["proxies_error"] = "⚠️ Не удалось загрузить прокси. Попробуйте позже."
MESSAGES["ru"]["proxies_list_title"] = "⚡ **Доступные прокси (топ по пингу):**"

MESSAGES["ru"]["menu_referral"] = "🎁 Пригласить друга"
MESSAGES["ru"]["menu_support"] = "🎧 Поддержка"
MESSAGES["ru"]["menu_status"] = "📊 Статус"
MESSAGES["ru"]["support_prompt"] = (
    "🎧 **Поддержка Mosaic**\n\n"
    "Выберите действие ниже — мы отвечаем 24/7."
)
MESSAGES["ru"]["referral_promo"] = (
    "🎁 **Получите VPN бесплатно**\n\n"
    "Пригласите друга в Mosaic VPN! Когда он оплатит подписку, вы **ОБА** получите бонусные дни.\n\n"
    "```"
    " FRIEND PAYS · 10 DAYS → +10 FOR BOTH\n"
    " FRIEND PAYS · 30 DAYS → +30 FOR BOTH\n"
    " FRIEND PAYS · 90 DAYS → +90 FOR BOTH\n"
    "```\n\n"
    "Без ограничений — приглашайте сколько угодно.\n\n"
    "Нажмите кнопку ниже, чтобы получить реферальную ссылку."
)
MESSAGES["ru"]["referral_link_text"] = "🔗 **Ваша реферальная ссылка:**\n`{link}`\n\nОтправьте её другу. Когда он запустит бота, система свяжет ваши профили."

MESSAGES["en"]["menu_proxies"] = "⚡ Free Proxies"
MESSAGES["en"]["proxies_welcome"] = "⚡ **Free MTProto & SOCKS5 Proxies**\n\nAutomatically verified proxies resistant to DPI blocking.\n\nSelect a category below:"
MESSAGES["en"]["proxies_loading"] = "⏳ Loading fresh proxies..."
MESSAGES["en"]["proxies_error"] = "⚠️ Failed to load proxies. Please try again later."
MESSAGES["en"]["proxies_list_title"] = "⚡ **Available proxies (top by latency):**"

MESSAGES["en"]["menu_referral"] = "🎁 Invite a Friend"
MESSAGES["en"]["menu_support"] = "🎧 Support"
MESSAGES["en"]["menu_status"] = "📊 Status"
MESSAGES["en"]["support_prompt"] = (
    "🎧 **Mosaic Support**\n\n"
    "Choose an action below — we're available 24/7."
)
MESSAGES["en"]["referral_promo"] = (
    "🎁 **Get VPN for free**\n\n"
    "Invite a friend to Mosaic VPN! When they purchase a subscription, you **BOTH** get bonus days.\n\n"
    "```"
    " FRIEND PAYS · 10 DAYS → +10 FOR BOTH\n"
    " FRIEND PAYS · 30 DAYS → +30 FOR BOTH\n"
    " FRIEND PAYS · 90 DAYS → +90 FOR BOTH\n"
    "```\n\n"
    "No limits — invite as many friends as you want!\n\n"
    "Click the button below to get your referral link."
)
MESSAGES["en"]["referral_link_text"] = "🔗 **Your referral link:**\n`{link}`\n\nShare it with a friend. When they start the bot, our system will link your accounts."

bot = telebot.TeleBot(BOT_TOKEN)

# Initialize Database
def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS users (
        telegram_id INTEGER PRIMARY KEY,
        username TEXT,
        short_uuid TEXT,
        language TEXT DEFAULT 'ru',
        trial_used INTEGER DEFAULT 0,
        created_at TEXT,
        referrer_id INTEGER
    )
    """)
    # Safe column adds for existing DBs
    for col, decl in [
        ("referrer_id", "INTEGER"),
        ("first_paid_at", "TEXT"),       # #12: rating prompt — when user first paid
        ("rating_given", "INTEGER DEFAULT 0"),  # #12: rating already submitted
        ("tickets_count", "INTEGER DEFAULT 0"),  # #10: total open+closed tickets
    ]:
        try:
            cursor.execute(f"ALTER TABLE users ADD COLUMN {col} {decl}")
        except sqlite3.OperationalError:
            pass
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS invoices (
        invoice_id INTEGER PRIMARY KEY,
        telegram_id INTEGER,
        amount REAL,
        months REAL,
        days INTEGER,
        status TEXT,
        created_at TEXT,
        promo_code TEXT,
        bonus_days INTEGER DEFAULT 0
    )
    """)
    for col, decl in [
        ("promo_code", "TEXT"),
        ("bonus_days", "INTEGER DEFAULT 0"),
        ("payment_provider", "TEXT DEFAULT 'cryptobot'"),
        ("provider_invoice_id", "TEXT"),
        ("order_id", "TEXT"),
    ]:
        try:
            cursor.execute(f"ALTER TABLE invoices ADD COLUMN {col} {decl}")
        except sqlite3.OperationalError:
            pass
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS notification_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        telegram_id INTEGER,
        notification_type TEXT,
        sent_at TEXT
    )
    """)
    # #2: Promo codes table
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS promo_codes (
        code TEXT PRIMARY KEY,
        days_bonus INTEGER DEFAULT 0,
        discount_percent INTEGER DEFAULT 0,
        max_uses INTEGER DEFAULT -1,
        used_count INTEGER DEFAULT 0,
        expires_at TEXT,
        created_at TEXT,
        created_by INTEGER
    )
    """)
    # #10: Support tickets
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS tickets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        telegram_id INTEGER,
        subject TEXT,
        status TEXT DEFAULT 'open',
        created_at TEXT,
        closed_at TEXT
    )
    """)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS ticket_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id INTEGER,
        sender TEXT,
        message TEXT,
        created_at TEXT
    )
    """)
    # #6: Rate-limit ledger (lightweight; pruned by age)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS rate_limits (
        telegram_id INTEGER,
        action TEXT,
        ts REAL,
        PRIMARY KEY (telegram_id, action, ts)
    )
    """)
    # #8: Referral leaderboard cache
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS referral_stats (
        referrer_id INTEGER PRIMARY KEY,
        clicks INTEGER DEFAULT 0,
        joined INTEGER DEFAULT 0,
        paid INTEGER DEFAULT 0,
        bonus_days_earned INTEGER DEFAULT 0
    )
    """)
    # #12: User ratings (1-5 stars after 3d usage)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS user_ratings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        telegram_id INTEGER,
        rating INTEGER,
        comment TEXT,
        created_at TEXT
    )
    """)
    # #13: Uptime pings (1 row per 5-min check)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS uptime_pings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts REAL,
        online INTEGER
    )
    """)
    # T-19: single-use pairing codes for linking the desktop/mobile client.
    # The daemon lives behind NAT on the user's machine, so the bot cannot
    # push a code to it: the bot issues, the daemon verifies over HTTP.
    cursor.execute("""
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
    """)
    # #13: User complaints (quick report-bad-connection)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS complaints (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        telegram_id INTEGER,
        category TEXT,
        detail TEXT,
        created_at TEXT
    )
    """)
    # Web cabinet sessions (long-lived, 30-day tokens for sub.zxc1x1.ru/cabinet)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS web_sessions (
        token TEXT PRIMARY KEY,
        telegram_id INTEGER NOT NULL,
        username TEXT,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
    )
    """)
    # Browser-to-app callbacks contain only this single-use five-minute code.
    # They never contain an account session token or personal feed URL.
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS app_auth_codes (
        code TEXT PRIMARY KEY,
        telegram_id INTEGER NOT NULL,
        username TEXT,
        state TEXT NOT NULL,
        purpose TEXT NOT NULL DEFAULT 'login',
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        used_at TEXT
    )
    """)
    # Existing installations created app_auth_codes before `purpose` existed.
    # Keep the migration additive so older callback rows retain login semantics.
    app_auth_columns = {row[1] for row in cursor.execute("PRAGMA table_info(app_auth_codes)")}
    if "purpose" not in app_auth_columns:
        cursor.execute("ALTER TABLE app_auth_codes ADD COLUMN purpose TEXT NOT NULL DEFAULT 'login'")

    # Administrative balance credits are an auditable, idempotent ledger.
    # A request remains `processing` until the remote subscription is updated,
    # so retrying after a network error never applies the same credit twice.
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS admin_balance_credits (
        request_id TEXT PRIMARY KEY,
        admin_telegram_id INTEGER NOT NULL,
        target_telegram_id INTEGER NOT NULL,
        amount_rub INTEGER NOT NULL,
        reason TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        completed_at TEXT,
        error TEXT,
        resulting_short_uuid TEXT
    )
    """)
    cursor.execute("""
    CREATE INDEX IF NOT EXISTS idx_admin_balance_credits_created
    ON admin_balance_credits(created_at DESC)
    """)
    conn.commit()
    conn.close()

# Database Helper Functions

# --- T-19: pairing codes for the desktop/mobile client ---------------------
# Ambiguous glyphs are excluded: a code is read off one screen and typed into
# another, so 0/O and 1/I/L would generate support tickets.
LINK_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
LINK_CODE_TTL_MINUTES = 10
LINK_CODE_MAX_ATTEMPTS = 5


def _link_code_normalise(raw):
    """Uppercase and strip separators so 'ab23-cd45' matches 'AB23CD45'."""
    if not raw:
        return ""
    return "".join(ch for ch in raw.upper() if ch in LINK_CODE_ALPHABET)


def issue_link_code(telegram_id, username, session_token=None):
    """Mint a single-use pairing code, invalidating any earlier unused one.

    Reissuing drops the previous code on purpose: leaving several live codes
    for one account widens the guessing window for no benefit.
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("DELETE FROM link_codes WHERE telegram_id = ? AND used_at IS NULL", (telegram_id,))
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = now + datetime.timedelta(minutes=LINK_CODE_TTL_MINUTES)
    for _ in range(12):
        code = "".join(secrets.choice(LINK_CODE_ALPHABET) for _ in range(8))
        try:
            cursor.execute(
                "INSERT INTO link_codes (code, telegram_id, username, session_token, issued_at, expires_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (code, telegram_id, username or "", session_token or "",
                 now.isoformat(), expires.isoformat()),
            )
            conn.commit()
            conn.close()
            return code, expires
        except sqlite3.IntegrityError:
            continue  # astronomically unlikely collision; just try again
    conn.close()
    raise RuntimeError("could not allocate a link code")


def redeem_link_code(raw_code):
    """Burn a pairing code.

    Returns (payload, None) on success or (None, reason) where reason is one
    of not_found / expired / used / attempts. The caller maps those onto HTTP
    statuses; the daemon needs the distinction to tell the user something
    true instead of a generic failure.
    """
    code = _link_code_normalise(raw_code)
    if not code:
        return None, "not_found"

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT telegram_id, username, session_token, expires_at, used_at, attempts "
        "FROM link_codes WHERE code = ?", (code,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        return None, "not_found"

    telegram_id, username, session_token, expires_at, used_at, attempts = row
    if used_at:
        conn.close()
        return None, "used"
    if attempts is not None and attempts >= LINK_CODE_MAX_ATTEMPTS:
        conn.close()
        return None, "attempts"

    try:
        expires = datetime.datetime.fromisoformat(expires_at)
    except (TypeError, ValueError):
        expires = None
    now = datetime.datetime.now(datetime.timezone.utc)
    if expires is not None:
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        if expires < now:
            conn.close()
            return None, "expired"

    # Mark used in the same transaction that reads it, so two clients racing
    # on one code cannot both succeed.
    cursor.execute(
        "UPDATE link_codes SET used_at = ?, attempts = attempts + 1 "
        "WHERE code = ? AND used_at IS NULL", (now.isoformat(), code))
    if cursor.rowcount == 0:
        conn.commit()
        conn.close()
        return None, "used"
    conn.commit()
    conn.close()
    return {
        "telegram_id": telegram_id,
        "username": username or "",
        "session_token": session_token or "",
    }, None


# --- Web cabinet sessions (30-day tokens for sub.zxc1x1.ru/cabinet) ----------

WEB_SESSION_TTL_DAYS = 30


def create_web_session(telegram_id, username):
    """Mint a long-lived token for the web cabinet."""
    import secrets as _secrets
    token = _secrets.token_urlsafe(32)
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = now + datetime.timedelta(days=WEB_SESSION_TTL_DAYS)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO web_sessions (token, telegram_id, username, created_at, expires_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (token, telegram_id, username or "", now.isoformat(), expires.isoformat()),
    )
    conn.commit()
    conn.close()
    return token, expires.isoformat()


def get_web_session(token):
    """Return {telegram_id, username} for a valid web session token, else None."""
    if not token or len(token) > 128:
        return None
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT telegram_id, username, expires_at FROM web_sessions WHERE token = ?",
        (token,),
    )
    row = cursor.fetchone()
    conn.close()
    if not row:
        return None
    telegram_id, username, expires_at = row
    try:
        expires = datetime.datetime.fromisoformat(expires_at)
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        if expires < datetime.datetime.now(datetime.timezone.utc):
            return None
    except (TypeError, ValueError):
        return None
    return {"telegram_id": telegram_id, "username": username or ""}


APP_AUTH_CODE_TTL_SECONDS = 300


def issue_app_auth_code(session_token, state, purpose="login"):
    """Create a short-lived, state-bound callback code for login or enrollment."""
    session = get_web_session(session_token)
    if purpose not in ("login", "enroll"):
        return None
    if not session or not state or len(state) < 16 or len(state) > 128:
        return None
    import secrets as _secrets
    code = _secrets.token_urlsafe(32)
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = now + datetime.timedelta(seconds=APP_AUTH_CODE_TTL_SECONDS)
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute(
            "INSERT INTO app_auth_codes (code, telegram_id, username, state, purpose, created_at, expires_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (code, session["telegram_id"], session["username"], state, purpose,
             now.isoformat(), expires.isoformat()),
        )
        conn.commit()
    finally:
        conn.close()
    return code


def redeem_app_auth_code(code, state):
    """Atomically burn a callback code and return the authenticated account."""
    if not code or not state or len(code) > 128 or len(state) > 128:
        return None, "invalid"
    now = datetime.datetime.now(datetime.timezone.utc)
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute("BEGIN IMMEDIATE")
        cursor = conn.cursor()
        cursor.execute(
            "SELECT telegram_id, username, state, purpose, expires_at, used_at FROM app_auth_codes WHERE code = ?",
            (code,),
        )
        row = cursor.fetchone()
        if not row:
            conn.rollback()
            return None, "not_found"
        telegram_id, username, expected_state, purpose, expires_at, used_at = row
        if used_at:
            conn.rollback()
            return None, "used"
        if expected_state != state:
            conn.rollback()
            return None, "state_mismatch"
        try:
            expiry = datetime.datetime.fromisoformat(expires_at)
            if expiry.tzinfo is None:
                expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        except (TypeError, ValueError):
            conn.rollback()
            return None, "expired"
        if expiry <= now:
            conn.rollback()
            return None, "expired"
        cursor.execute(
            "UPDATE app_auth_codes SET used_at = ? WHERE code = ? AND used_at IS NULL",
            (now.isoformat(), code),
        )
        if cursor.rowcount != 1:
            conn.rollback()
            return None, "used"
        conn.commit()
    finally:
        conn.close()
    return {"telegram_id": telegram_id, "username": username or "", "purpose": purpose or "login"}, None


def get_payments_history(telegram_id):
    """Return list of paid invoices for the web cabinet."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT invoice_id, amount, days, status, created_at "
        "FROM invoices WHERE telegram_id = ? ORDER BY created_at DESC LIMIT 50",
        (telegram_id,),
    )
    rows = cursor.fetchall()
    conn.close()
    return [
        {
            "id": r[0],
            "amount": r[1],
            "days": r[2],
            "status": r[3],
            "date": r[4],
        }
        for r in rows
    ]


ADMIN_CREDIT_MAX_RUB = 100000


def claim_admin_balance_credit(request_id, admin_telegram_id, target_telegram_id, amount_rub, reason):
    """Atomically record an admin credit before touching the subscription API.

    Returns the current record and whether this call inserted it. A duplicate
    request id is intentionally not retried: it lets the caller distinguish a
    completed action from one that needs manual reconciliation after an outage.
    """
    conn = sqlite3.connect(DB_PATH, timeout=8)
    try:
        cursor = conn.cursor()
        cursor.execute("BEGIN IMMEDIATE")
        cursor.execute(
            "SELECT admin_telegram_id, target_telegram_id, amount_rub, reason, status, "
            "created_at, completed_at, error, resulting_short_uuid "
            "FROM admin_balance_credits WHERE request_id = ?", (request_id,))
        row = cursor.fetchone()
        if row:
            conn.commit()
            return {
                "request_id": request_id, "admin_telegram_id": row[0], "target_telegram_id": row[1],
                "amount_rub": row[2], "reason": row[3], "status": row[4], "created_at": row[5],
                "completed_at": row[6], "error": row[7], "resulting_short_uuid": row[8],
            }, False
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        cursor.execute(
            "INSERT INTO admin_balance_credits "
            "(request_id, admin_telegram_id, target_telegram_id, amount_rub, reason, status, created_at) "
            "VALUES (?, ?, ?, ?, ?, 'processing', ?)",
            (request_id, admin_telegram_id, target_telegram_id, amount_rub, reason, now))
        conn.commit()
        return {
            "request_id": request_id, "admin_telegram_id": admin_telegram_id,
            "target_telegram_id": target_telegram_id, "amount_rub": amount_rub,
            "reason": reason, "status": "processing", "created_at": now,
            "completed_at": None, "error": None, "resulting_short_uuid": None,
        }, True
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def finish_admin_balance_credit(request_id, status, error=None, resulting_short_uuid=None):
    """Finalize a claimed admin credit without ever moving it back to pending."""
    if status not in {"succeeded", "failed"}:
        raise ValueError("invalid admin credit status")
    conn = sqlite3.connect(DB_PATH)
    try:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE admin_balance_credits SET status = ?, completed_at = ?, error = ?, resulting_short_uuid = ? "
            "WHERE request_id = ? AND status = 'processing'",
            (status, datetime.datetime.now(datetime.timezone.utc).isoformat(), error, resulting_short_uuid, request_id))
        conn.commit()
        return cursor.rowcount == 1
    finally:
        conn.close()


def get_admin_balance_credit_history(limit=50):
    """Return the recent administrative credits; callers must authorize first."""
    safe_limit = max(1, min(int(limit), 100))
    conn = sqlite3.connect(DB_PATH)
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT request_id, admin_telegram_id, target_telegram_id, amount_rub, reason, status, "
            "created_at, completed_at, error FROM admin_balance_credits "
            "ORDER BY created_at DESC LIMIT ?", (safe_limit,))
        rows = cursor.fetchall()
    finally:
        conn.close()
    return [
        {
            "request_id": row[0], "admin_telegram_id": row[1], "target_telegram_id": row[2],
            "amount": row[3], "reason": row[4], "status": row[5], "created_at": row[6],
            "completed_at": row[7], "error": row[8],
        }
        for row in rows
    ]


def get_user(telegram_id):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT username, short_uuid, language, trial_used, referrer_id FROM users WHERE telegram_id = ?", (telegram_id,))
    row = cursor.fetchone()
    conn.close()
    if row:
        return {"username": row[0], "short_uuid": row[1], "language": row[2], "trial_used": row[3], "referrer_id": row[4]}
    return None

def save_user(telegram_id, username, short_uuid, language='ru', trial_used=0, referrer_id=None):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO users (telegram_id, username, short_uuid, language, trial_used, created_at, referrer_id)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(telegram_id) DO UPDATE SET
        username = excluded.username,
        short_uuid = excluded.short_uuid,
        language = excluded.language,
        trial_used = excluded.trial_used,
        referrer_id = CASE WHEN users.referrer_id IS NULL THEN excluded.referrer_id ELSE users.referrer_id END
    """, (telegram_id, username, short_uuid, language, trial_used, datetime.datetime.now().isoformat(), referrer_id))
    conn.commit()
    conn.close()

def update_user_lang(telegram_id, language):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("UPDATE users SET language = ? WHERE telegram_id = ?", (language, telegram_id))
    conn.commit()
    conn.close()

def save_invoice(invoice_id, telegram_id, amount, months, days):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO invoices (invoice_id, telegram_id, amount, months, days, status, created_at)
    VALUES (?, ?, ?, ?, ?, 'pending', ?)
    """, (invoice_id, telegram_id, amount, months, days, datetime.datetime.now().isoformat()))
    conn.commit()
    conn.close()

def save_lava_invoice(internal_id, provider_invoice_id, order_id, telegram_id, amount, days, store):
    """Persist a Lava invoice before showing its payment URL to the user."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO invoices (invoice_id, telegram_id, amount, months, days, status, created_at, payment_provider, provider_invoice_id, order_id) "
        "VALUES (?, ?, ?, ?, ?, 'pending', ?, 'lava_' || ?, ?, ?)",
        (internal_id, telegram_id, amount, days / 30.0, days, datetime.datetime.now().isoformat(), store, provider_invoice_id, order_id),
    )
    conn.commit()
    conn.close()


def get_lava_invoice(order_id=None, provider_invoice_id=None):
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    if provider_invoice_id:
        cursor.execute(
            "SELECT invoice_id, telegram_id, days, amount, status, payment_provider FROM invoices "
            "WHERE payment_provider LIKE 'lava_%' AND provider_invoice_id = ? LIMIT 1",
            (str(provider_invoice_id),),
        )
    else:
        cursor.execute(
            "SELECT invoice_id, telegram_id, days, amount, status, payment_provider FROM invoices "
            "WHERE payment_provider LIKE 'lava_%' AND order_id = ? LIMIT 1",
            (str(order_id),),
        )
    row = cursor.fetchone()
    conn.close()
    if not row:
        return None
    return {"invoice_id": row[0], "telegram_id": row[1], "days": row[2], "amount": row[3], "status": row[4], "store": row[5].replace("lava_", "", 1)}


def process_lava_paid_invoice(invoice):
    """Claim and credit a Lava invoice exactly once."""
    if not invoice or not update_invoice_status(invoice["invoice_id"], "paid"):
        return False
    telegram_id = invoice["telegram_id"]
    days = int(invoice["days"])
    username = f"tg_{telegram_id}"
    user = api_get_user(username)
    lava_updater = api_extend_user if user else api_create_user
    lava_updated = lava_updater(username, days) if user else lava_updater(username, days, telegram_id)
    if not lava_updated:
        logger.error("Lava payment %s claimed but subscription update failed", invoice["invoice_id"])
        return False
    lava_short_uuid = lava_updated.get("shortUuid")
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    save_user(telegram_id, username, lava_short_uuid, lang, 1, db_user.get("referrer_id") if db_user else None)
    send_payment_success_notification(telegram_id, days, lava_short_uuid, lava_updated.get("expireAt"), lang)
    logger.info("Lava invoice %s paid by %s for %s days", invoice["invoice_id"], telegram_id, days)
    return True


def get_pending_invoices():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT invoice_id, telegram_id, days FROM invoices WHERE status = 'pending'")
    rows = cursor.fetchall()
    conn.close()
    return rows

def update_invoice_status(invoice_id, status, expect="pending"):
    """Atomically transition an invoice's status.

    Returns True only if THIS call performed the transition. The guard on the
    previous status is what makes subscription accrual idempotent: the bot runs
    under `Restart=always` and polls in a background thread, so the same paid
    invoice can be observed twice (restart mid-accrual, or two poll cycles
    overlapping). Without the guard both observers would call api_extend_user
    and the user would be credited twice for one payment.

    Pass expect=None to force the write regardless of the current status.
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    if expect is None:
        cursor.execute(
            "UPDATE invoices SET status = ? WHERE invoice_id = ?",
            (status, invoice_id),
        )
    else:
        cursor.execute(
            "UPDATE invoices SET status = ? WHERE invoice_id = ? AND status = ?",
            (status, invoice_id, expect),
        )
    changed = cursor.rowcount == 1
    conn.commit()
    conn.close()
    return changed

def get_all_tg_users():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT telegram_id FROM users")
    rows = cursor.fetchall()
    conn.close()
    return [r[0] for r in rows]

# Admin verification
def is_admin(telegram_id):
    # Fast path: check the in-memory ADMIN_IDS set (env var or owner fallback).
    if telegram_id in ADMIN_IDS:
        return True
    # Slow path: optionally check the admins.txt file for ad-hoc additions.
    # The web profile endpoint must remain available even in read-only test or
    # container environments where /opt/mosaic-bot cannot be created.
    try:
        if not os.path.exists(ADMIN_FILE):
            admin_dir = os.path.dirname(ADMIN_FILE)
            if admin_dir:
                os.makedirs(admin_dir, exist_ok=True)
            with open(ADMIN_FILE, "w") as f:
                f.write("")  # empty — ADMIN_IDS is the source of truth
        with open(ADMIN_FILE, "r") as f:
            admins = [int(line.strip()) for line in f if line.strip().isdigit()]
        return telegram_id in admins
    except (OSError, ValueError):
        return False

# Remnawave API helper functions
def api_get_headers():
    return {
        "Authorization": f"Bearer {API_TOKEN}",
        "Content-Type": "application/json",
        "X-Forwarded-Proto": "https",
        "X-Forwarded-For": "127.0.0.1"
    }

def api_get_user(username):
    url = f"{BASE_URL}/api/users/by-username/{username}"
    try:
        res = requests.get(url, headers=api_get_headers(), timeout=15)
        if res.status_code == 200:
            return res.json().get("response")
    except Exception as e:
        logger.error(f"Error fetching user by username: {e}")
    return None

def api_create_user(username, days, telegram_id):
    url = f"{BASE_URL}/api/users"
    now = datetime.datetime.now(datetime.timezone.utc)
    expire_at = now + datetime.timedelta(days=days)
    expire_str = expire_at.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    
    payload = {
        "username": username,
        "expireAt": expire_str,
        "trafficLimitBytes": 0,
        "activeInternalSquads": [SQUAD_UUID],
        "telegramId": int(telegram_id)
    }
    try:
        res = requests.post(url, headers=api_get_headers(), json=payload, timeout=15)
        if res.status_code in [200, 201]:
            return res.json().get("response")
        else:
            logger.error(f"Create user failed: {res.status_code} - {res.text}")
    except Exception as e:
        logger.error(f"Error creating user: {e}")
    return None

def api_extend_user(username, days):
    user = api_get_user(username)
    if not user:
        return None
        
    current_expire_str = user.get("expireAt")
    now = datetime.datetime.now(datetime.timezone.utc)
    
    try:
        current_expire = dateutil.parser.isoparse(current_expire_str)
    except Exception as e:
        current_expire = now
        
    if current_expire < now:
        new_expire = now + datetime.timedelta(days=days)
    else:
        new_expire = current_expire + datetime.timedelta(days=days)
        
    new_expire_str = new_expire.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    
    url = f"{BASE_URL}/api/users"
    payload = {
        "username": username,
        "expireAt": new_expire_str
    }
    try:
        res = requests.patch(url, headers=api_get_headers(), json=payload, timeout=15)
        if res.status_code == 200:
            return res.json().get("response")
        else:
            logger.error(f"Extend user failed: {res.status_code} - {res.text}")
    except Exception as e:
        logger.error(f"Error extending user: {e}")
    return None


def api_user_action(username, action):
    """Execute a documented Remnawave user action by immutable user ID."""
    if action not in {"disable", "enable", "revoke"}:
        raise ValueError("unsupported user action")
    user = api_get_user(username)
    if not user:
        return None
    user_id = user.get("uuid") or user.get("id")
    if not user_id:
        logger.error("Remnawave user %s has no user ID", username)
        return None
    url = f"{BASE_URL}/api/users/{user_id}/actions/{action}"
    try:
        res = requests.post(url, headers=api_get_headers(), json={}, timeout=15)
        if res.status_code in (200, 201, 204):
            if res.content:
                return res.json().get("response") or user
            return user
        logger.error("User %s action failed for %s: %s - %s", action, username,
                     res.status_code, res.text)
    except Exception as exc:
        logger.error("User %s action error for %s: %s", action, username, exc)
    return None


def api_disable_user(username):
    return api_user_action(username, "disable")


def api_enable_user(username):
    return api_user_action(username, "enable")


def api_revoke_user_subscription(username):
    """Rotate the provider-issued public subscription link for a user."""
    return api_user_action(username, "revoke")


def api_get_user_devices(username, user=None):
    """Return real HWID device rows when the provider exposes them.

    The endpoint is optional from the client cabinet's perspective: a provider
    outage must result in an empty device list, never fabricated devices.
    """
    user = user or api_get_user(username)
    if not user:
        return []
    user_id = user.get("id") or user.get("userId")
    if user_id is None:
        return []
    try:
        res = requests.get(
            f"{BASE_URL}/api/hwid/devices/{user_id}",
            headers=api_get_headers(), timeout=12)
        if res.status_code != 200:
            logger.warning("HWID devices request failed for %s: HTTP %s", username, res.status_code)
            return []
        body = res.json().get("response", [])
        return body if isinstance(body, list) else []
    except Exception as exc:
        logger.warning("HWID devices request error for %s: %s", username, exc)
        return []


def _cabinet_device_rows(rows):
    """Project provider device data into a privacy-preserving cabinet view."""
    devices = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        # Provider schemas vary; retain only display-safe labels and timestamps.
        label = str(row.get("deviceName") or row.get("name") or row.get("userAgent") or "Устройство")
        platform = str(row.get("platform") or row.get("os") or "")
        last_seen = row.get("updatedAt") or row.get("lastSeenAt") or row.get("createdAt")
        devices.append({
            "id": str(row.get("id") or row.get("uuid") or ""),
            "label": label[:120],
            "platform": platform[:80],
            "last_seen_at": last_seen,
        })
    return devices

# Lava Business API integration
LAVA_STORE_CONFIG = {
    "site": {
        "shop_id": LAVA_SITE_SHOP_ID,
        "secret_key": LAVA_SITE_SECRET_KEY,
        "additional_key": LAVA_SITE_ADDITIONAL_KEY,
        "success_url": LAVA_SITE_SUCCESS_URL,
        "fail_url": LAVA_SITE_FAIL_URL,
        "webhook_path": LAVA_WEBHOOK_SITE_PATH,
    },
    "bot": {
        "shop_id": LAVA_BOT_SHOP_ID,
        "secret_key": LAVA_BOT_SECRET_KEY,
        "additional_key": LAVA_BOT_ADDITIONAL_KEY,
        "success_url": LAVA_BOT_SUCCESS_URL,
        "fail_url": LAVA_BOT_FAIL_URL,
        "webhook_path": LAVA_WEBHOOK_BOT_PATH,
    },
}


def lava_store_config(store):
    config = LAVA_STORE_CONFIG.get(store)
    if not config or not config["shop_id"] or not config["secret_key"] or not config["additional_key"]:
        raise RuntimeError(f"Lava store {store!r} is not configured")
    return config


def _lava_signed_request(path, payload, secret_key):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    signature = hmac.new(secret_key.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).hexdigest()
    response = requests.post(
        f"{LAVA_API_BASE}/{path.lstrip('/')}",
        data=body.encode("utf-8"),
        headers={"Accept": "application/json", "Content-Type": "application/json", "Signature": signature},
        timeout=20,
    )
    try:
        data = response.json()
    except ValueError:
        data = {}
    if response.status_code >= 400 or data.get("status_check") is False or data.get("error"):
        raise RuntimeError(f"Lava API error {response.status_code}: {data.get('error', response.text[:300])}")
    return data.get("data") or data


def _lava_value(data, *keys, default=None):
    if not isinstance(data, dict):
        return default
    for key in keys:
        value = data.get(key)
        if value is not None and value != "":
            return value
    return default


def available_lava_consumer_services(store):
    """Return active SBP/card service IDs for one merchant shop.

    Lava projects can have a different approved method set. Querying the
    official tariff endpoint prevents showing an empty checkout or the
    merchant's internal Lava wallet sign-in to ordinary MosaicVPN customers.
    """
    config = lava_store_config(store)
    data = _lava_signed_request(
        "invoice/get-available-tariffs",
        {"shopId": config["shop_id"]},
        config["secret_key"],
    )
    tariffs = data if isinstance(data, list) else []
    return [
        str(item.get("service_id")).lower()
        for item in tariffs
        if isinstance(item, dict)
        and str(item.get("service_id", "")).lower() in LAVA_CONSUMER_SERVICES
    ]


def create_lava_invoice(store, telegram_id, amount, days, description=None):
    config = lava_store_config(store)
    amount = round(float(amount), 2)
    if amount < 1 or amount > 100000:
        raise ValueError("amount must be between 1 and 100000 RUB")
    if days < 1 or days > 100000:
        raise ValueError("days must be between 1 and 100000")
    active_services = available_lava_consumer_services(store)
    if not active_services:
        raise RuntimeError(
            "В магазине пока не активированы способы оплаты СБП или банковской картой. "
            "Пожалуйста, попробуйте позже."
        )
    internal_id = secrets.randbelow(9_000_000_000_000_000_000) + 1
    order_id = f"mosaic-{store}-{telegram_id}-{secrets.token_urlsafe(10)}"
    payload = {
        "sum": amount,
        "orderId": order_id,
        "shopId": config["shop_id"],
        "comment": description or f"MosaicVPN: пополнение на {days} дней",
        "hookUrl": f"https://sub.zxc1x1.ru{config['webhook_path']}",
        "successUrl": config["success_url"],
        "failUrl": config["fail_url"],
        "includeService": active_services,
    }
    data = _lava_signed_request("invoice/create", payload, config["secret_key"])
    provider_id = str(_lava_value(data, "id", "invoiceId", "invoice_id", default=internal_id))
    payment_url = _lava_value(data, "paymentUrl", "payment_url", "url", "link")
    if not payment_url:
        raise RuntimeError("Lava API did not return a payment URL")
    return {
        "internal_id": internal_id,
        "provider_id": provider_id,
        "order_id": order_id,
        "payment_url": payment_url,
        "amount": amount,
        "days": days,
        "store": store,
    }


def verify_lava_webhook(store, body, signature):
    config = lava_store_config(store)
    if not signature:
        return False
    expected = hmac.new(config["additional_key"].encode("utf-8"), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature.strip(), expected)


def get_lava_invoice_status(store, order_id):
    config = lava_store_config(store)
    data = _lava_signed_request("invoice/status", {"shopId": config["shop_id"], "orderId": order_id}, config["secret_key"])
    return str(_lava_value(data, "status", "state", default="pending")).lower()


# CryptoPay integration
def create_cryptopay_invoice(amount, days):
    url = "https://pay.crypt.bot/api/createInvoice"
    headers = {"Crypto-Pay-API-Token": CRYPTO_PAY_TOKEN}
    payload = {
        "amount": amount,
        "asset": "USDT",
        "description": f"MosaicVPN Atlas Top Up - {days} subscription days",
        "allow_comments": False,
        "allow_anonymous": False,
        "expires_in": 1800
    }
    try:
        res = requests.post(url, headers=headers, json=payload, timeout=15)
        if res.status_code == 200:
            data = res.json()
            if data.get("ok"):
                result = data.get("result", {})
                return result.get("invoice_id"), result.get("pay_url")
        logger.error(f"CryptoPay error: {res.status_code} - {res.text}")
    except Exception as e:
        logger.error(f"Error creating CryptoPay invoice: {e}")
    return None, None

def check_cryptopay_invoice(invoice_id):
    url = "https://pay.crypt.bot/api/getInvoices"
    headers = {"Crypto-Pay-API-Token": CRYPTO_PAY_TOKEN}
    payload = {"invoice_ids": str(invoice_id)}
    try:
        res = requests.post(url, headers=headers, json=payload, timeout=15)
        if res.status_code == 200:
            data = res.json()
            if data.get("ok"):
                items = data.get("result", {}).get("items", [])
                if items:
                    return items[0].get("status")
    except Exception as e:
        logger.error(f"Error checking CryptoPay invoice {invoice_id}: {e}")
    return None

# Invoice background polling thread
def get_user_lang(telegram_id):
    db_user = get_user(telegram_id)
    return db_user["language"] if db_user else "ru"

def polling_invoices_thread():
    logger.info("Invoice polling thread started.")
    while True:
        try:
            pending = get_pending_invoices()
            for invoice_id, telegram_id, days in pending:
                status = check_cryptopay_invoice(invoice_id)
                if status == "paid":
                    # Claim the invoice BEFORE crediting anything. update_invoice_status
                    # returns False when another poll cycle (or a pre-restart run) already
                    # moved it out of 'pending', which means the subscription was already
                    # extended — crediting again would give a free month per restart.
                    if not update_invoice_status(invoice_id, "paid"):
                        logger.info(
                            f"Invoice {invoice_id} already processed (status != pending); skipping accrual"
                        )
                        continue
                    logger.info(f"Invoice {invoice_id} paid by {telegram_id} for {days} days!")

                    username = f"tg_{telegram_id}"
                    user = api_get_user(username)
                    
                    if user:
                        updated = api_extend_user(username, days)
                        if updated:
                            short_uuid = updated.get("shortUuid")
                            db_user = get_user(telegram_id)
                            lang = db_user["language"] if db_user else "ru"
                            save_user(telegram_id, username, short_uuid, lang, 1, db_user.get("referrer_id") if db_user else None)
                            send_payment_success_notification(telegram_id, days, short_uuid, updated.get("expireAt"), lang)
                    else:
                        created = api_create_user(username, days, telegram_id)
                        if created:
                            short_uuid = created.get("shortUuid")
                            db_user = get_user(telegram_id)
                            lang = db_user["language"] if db_user else "ru"
                            save_user(telegram_id, username, short_uuid, lang, 1, db_user.get("referrer_id") if db_user else None)
                            send_payment_success_notification(telegram_id, days, short_uuid, created.get("expireAt"), lang)
                            
                    # Referral bonus accrual
                    db_user = get_user(telegram_id)
                    referrer_id = db_user.get("referrer_id") if db_user else None
                    if referrer_id:
                        ref_username = f"tg_{referrer_id}"
                        ref_user = api_get_user(ref_username)
                        if not ref_user:
                            logger.warning(f"Referrer {referrer_id} ({ref_username}) not found in Remnawave — bonus skipped")
                        if ref_user:
                            ref_updated = api_extend_user(ref_username, days)
                            if not ref_updated:
                                logger.error(f"Failed to extend subscription for referrer {referrer_id} — api_extend_user returned None")
                            if ref_updated:
                                # #1: Update referral stats — paid + bonus_days
                                ref_stats_incr(referrer_id, "paid", by=1)
                                ref_stats_incr(referrer_id, "bonus_days_earned", by=days)
                                ref_lang = get_user_lang(referrer_id)
                                if ref_lang == "ru":
                                    ref_text = (
                                        f"🎉 Вам начислен бонус за приглашённого друга!\n\n"
                                        f"Вы получили **{days} дней** бесплатной подписки. "
                                        f"Приглашайте ещё — бонус за каждого друга."
                                    )
                                    ref_button_text = "🎁 Пригласить ещё"
                                else:
                                    ref_text = (
                                        f"🎉 You received a bonus for inviting a friend!\n\n"
                                        f"You got **{days} days** of free subscription. "
                                        f"Invite more friends to get more bonus days!"
                                    )
                                    ref_button_text = "🎁 Invite more"
                                
                                markup = types.InlineKeyboardMarkup()
                                markup.add(types.InlineKeyboardButton(ref_button_text, callback_data="ref_link"))
                                try:
                                    bot.send_message(referrer_id, ref_text, parse_mode="Markdown", reply_markup=markup)
                                except Exception as e:
                                    logger.error(f"Failed to send ref bonus message to {referrer_id}: {e}")
                                
                                # Bonus for referral himself (notification only — subscription already extended above)
                                try:
                                    lang = db_user["language"] if db_user else "ru"
                                    if lang == "ru":
                                        success_ref_text = f"🎁 Вам также зачислено +{days} бонусных дней за то, что вы пришли по приглашению друга!"
                                    else:
                                        success_ref_text = f"🎁 You also received +{days} bonus days for joining via friend invitation!"
                                    bot.send_message(telegram_id, success_ref_text, parse_mode="Markdown")
                                except Exception as e:
                                    logger.error(f"Failed to send bonus info to ref {telegram_id}: {e}")
                            
                elif status in ["expired", "cancelled"]:
                    logger.info(f"Invoice {invoice_id} status changed to {status}. Cancelling in DB.")
                    if update_invoice_status(invoice_id, status):
                        logger.info(f"Invoice {invoice_id} marked as {status}")
                    else:
                        logger.debug(f"Invoice {invoice_id} already not pending (got {status})")
        except Exception as e:
            logger.error(f"Error in polling loop: {e}")
        time.sleep(10)

def send_payment_success_notification(telegram_id, days, short_uuid, expire_at_str, lang):
    try:
        expire_date = dateutil.parser.isoparse(expire_at_str).strftime("%Y-%m-%d")
    except Exception:
        expire_date = expire_at_str
        
    sub_url = f"https://sub.zxc1x1.ru/{short_uuid}"
    
    t = MESSAGES[lang]
    text = t["payment_success"].format(days=days, expire_date=expire_date, sub_url=sub_url)
    
    markup = types.InlineKeyboardMarkup()
    markup.add(types.InlineKeyboardButton("🗺 Web Map" if lang == 'en' else "🗺 Открыть веб-карту", url=sub_url))
    markup.add(types.InlineKeyboardButton("⚡ Бесплатные прокси" if lang == 'ru' else "⚡ Free Proxies", callback_data="proxy_all"))
    
    try:
        bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)
    except Exception as e:
        logger.error(f"Failed to send message to user {telegram_id}: {e}")


# ============================================================
# #6: Anti-spam rate-limit helpers
# ============================================================
RATE_LIMIT_RULES = {
    "message": (5, 60),        # 5 messages per 60s
    "ref_click": (10, 86400),  # 10 ref-link clicks per day
    "ticket": (3, 3600),      # 3 tickets per hour
    "promo_apply": (3, 3600),  # 3 promo redemptions per hour
    "rating": (1, 86400),     # 1 rating per day
    "broadcast": (1, 60),     # admin broadcast: 1/min
}

def rate_limit_check(telegram_id, action):
    """Return True if action allowed (within limit), False if blocked."""
    max_count, window = RATE_LIMIT_RULES.get(action, (10, 60))
    now = time.time()
    cutoff = now - window
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    # prune old entries for this action
    c.execute("DELETE FROM rate_limits WHERE action=? AND ts<?", (action, cutoff))
    c.execute("SELECT COUNT(*) FROM rate_limits WHERE telegram_id=? AND action=? AND ts>=?",
              (telegram_id, action, cutoff))
    count = c.fetchone()[0]
    if count >= max_count:
        conn.commit(); conn.close()
        return False
    c.execute("INSERT OR IGNORE INTO rate_limits (telegram_id, action, ts) VALUES (?,?,?)",
              (telegram_id, action, now))
    conn.commit(); conn.close()
    return True


# ============================================================
# #1, #8: Referral stats helpers
# ============================================================
def ref_stats_incr(referrer_id, field, by=1):
    """Increment referral_stats counter for referrer.

    field must be one of the known column names — we validate against a whitelist
    instead of interpolating into SQL to prevent injection through the f-string
    that was here before: anyone calling ref_stats_incr(0, '1=1; DROP TABLE ...')
    would have executed arbitrary SQL.
    """
    allowed_fields = {"clicks", "joined", "paid", "bonus_days_earned"}
    if field not in allowed_fields:
        logger.error(f"ref_stats_incr: invalid field {field!r}, ignoring")
        return
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("INSERT OR IGNORE INTO referral_stats (referrer_id, clicks, joined, paid, bonus_days_earned) VALUES (?,0,0,0,0)",
              (referrer_id,))
    c.execute(f"UPDATE referral_stats SET {field}={field}+? WHERE referrer_id=?", (by, referrer_id))
    conn.commit(); conn.close()

def ref_stats_get(referrer_id):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    try:
        c.execute("INSERT INTO referral_stats (referrer_id, clicks, joined, paid, bonus_days_earned) VALUES (?,0,0,0,0)",
                  (referrer_id,))
        conn.commit()
    except sqlite3.IntegrityError:
        pass
    c.execute("SELECT clicks, joined, paid, bonus_days_earned FROM referral_stats WHERE referrer_id=?",
              (referrer_id,))
    row = c.fetchone(); conn.close()
    return {"clicks": row[0], "joined": row[1], "paid": row[2], "bonus_days_earned": row[3]}

def ref_leaderboard_top(limit=10):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT referrer_id, joined, paid, bonus_days_earned FROM referral_stats ORDER BY paid DESC, joined DESC LIMIT ?",
              (limit,))
    rows = c.fetchall(); conn.close()
    return rows


# ============================================================
# #2: Promo codes helpers
# ============================================================
def promo_create(code, days_bonus=0, discount_percent=0, max_uses=-1, expires_at=None, created_by=None):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    try:
        c.execute("INSERT INTO promo_codes (code, days_bonus, discount_percent, max_uses, expires_at, created_at, created_by) VALUES (?,?,?,?,?,?,?)",
                  (code.upper(), days_bonus, discount_percent, max_uses, expires_at,
                   datetime.datetime.now(timezone.utc).isoformat(), created_by))
        conn.commit(); conn.close()
        return True
    except sqlite3.IntegrityError:
        conn.close()
        return False

def promo_validate(code):
    """Return (days_bonus, discount_percent) if valid, else None."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT days_bonus, discount_percent, max_uses, used_count, expires_at FROM promo_codes WHERE code=?",
              (code.upper(),))
    row = c.fetchone(); conn.close()
    if not row:
        return None
    days_bonus, discount_percent, max_uses, used_count, expires_at = row
    if max_uses >= 0 and used_count >= max_uses:
        return None
    if expires_at:
        try:
            if datetime.datetime.fromisoformat(expires_at) < datetime.datetime.now(timezone.utc):
                return None
        except Exception:
            pass
    return days_bonus, discount_percent

def promo_consume(code):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("UPDATE promo_codes SET used_count=used_count+1 WHERE code=?", (code.upper(),))
    conn.commit(); conn.close()


# ============================================================
# #3: Server status helper (Remnawave health + nearest node ping)
# ============================================================
def get_server_status(short_uuid):
    """Return dict {online: bool, expired: bool, expire_at: str} for user's sub."""
    try:
        user_info = api_get_user(f"tg_")  # placeholder for API circle check
    except Exception:
        pass
    # Use more direct: GET /api/users/by-username
    try:
        headers = api_get_headers()
        r = requests.get(f"{BASE_URL}/api/system/stats", headers=headers,
                         timeout=10, proxies={"http": None, "https": None})
        if r.status_code == 200:
            return {"online": True, "expire_at": None}
        return {"online": False, "expire_at": None}
    except Exception as e:
        logger.warning(f"Server status check failed: {e}")
        return {"online": False, "expire_at": None}


# ============================================================
# #10: Support ticket helpers
# ============================================================
def ticket_create(telegram_id, subject):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("INSERT INTO tickets (telegram_id, subject, status, created_at) VALUES (?,?,?,?)",
              (telegram_id, subject, "open", datetime.datetime.now(timezone.utc).isoformat()))
    ticket_id = c.lastrowid
    c.execute("UPDATE users SET tickets_count=tickets_count+1 WHERE telegram_id=?", (telegram_id,))
    conn.commit(); conn.close()
    return ticket_id

def ticket_add_message(ticket_id, sender, message):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("INSERT INTO ticket_messages (ticket_id, sender, message, created_at) VALUES (?,?,?,?)",
              (ticket_id, sender, message, datetime.datetime.now(timezone.utc).isoformat()))
    conn.commit(); conn.close()

def ticket_list_open():
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("""SELECT t.id, t.telegram_id, t.subject, t.created_at, u.username
                 FROM tickets t LEFT JOIN users u ON t.telegram_id=u.telegram_id
                 WHERE t.status='open' ORDER BY t.created_at DESC""")
    rows = c.fetchall(); conn.close()
    return rows

def ticket_close(ticket_id):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("UPDATE tickets SET status='closed', closed_at=? WHERE id=?",
              (datetime.datetime.now(timezone.utc).isoformat(), ticket_id))
    conn.commit(); conn.close()


# ============================================================
# #12: User rating helpers
# ============================================================
def rating_save(telegram_id, rating, comment=None):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("INSERT INTO user_ratings (telegram_id, rating, comment, created_at) VALUES (?,?,?,?)",
              (telegram_id, rating, comment, datetime.datetime.now(timezone.utc).isoformat()))
    c.execute("UPDATE users SET rating_given=1 WHERE telegram_id=?", (telegram_id,))
    conn.commit(); conn.close()

def rating_get_average():
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT AVG(rating), COUNT(*) FROM user_ratings")
    row = c.fetchone(); conn.close()
    return {"avg": row[0], "count": row[1]}


# ============================================================
# #13: Uptime monitoring + complaints
# ============================================================
def uptime_record_ping(online):
    """Record a 5-min ping result and prune old entries (>7 days)."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    now = time.time()
    c.execute("INSERT INTO uptime_pings (ts, online) VALUES (?,?)", (now, 1 if online else 0))
    c.execute("DELETE FROM uptime_pings WHERE ts < ?", (now - 7*86400,))
    conn.commit(); conn.close()

def uptime_get_percent(hours=24):
    """Return uptime % for the last N hours."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    cutoff = time.time() - hours * 3600
    c.execute("SELECT COUNT(*) FROM uptime_pings WHERE ts >= ?", (cutoff,))
    total = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM uptime_pings WHERE ts >= ? AND online=1", (cutoff,))
    online_count = c.fetchone()[0]
    conn.close()
    if total == 0:
        return 100.0  # no data yet — assume fine
    return round(100.0 * online_count / total, 1)

def uptime_get_last_offline():
    """Return (ts, online) of the most recent ping, or None."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT ts, online FROM uptime_pings ORDER BY id DESC LIMIT 1")
    row = c.fetchone(); conn.close()
    return row if row else None

def complaint_create(telegram_id, category, detail=""):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("INSERT INTO complaints (telegram_id, category, detail, created_at) VALUES (?,?,?,?)",
              (telegram_id, category, detail, datetime.datetime.now(timezone.utc).isoformat()))
    complaint_id = c.lastrowid
    conn.commit(); conn.close()
    return complaint_id

def complaint_count_recent(hours=1):
    """Count complaints in the last N hours."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    cutoff = time.time() - hours * 3600
    # created_at is ISO format, convert to epoch for comparison
    c.execute("""SELECT COUNT(*) FROM complaints
                 WHERE datetime(created_at) >= datetime(?, 'unixepoch')""", (cutoff,))
    count = c.fetchone()[0]; conn.close()
    return count

def admin_alert(text):
    """Send an urgent alert to all admins."""
    for admin_id in ADMIN_IDS:
        try:
            bot.send_message(admin_id, f"🚨 **АЛЕРТ**\n\n{text}", parse_mode="Markdown")
        except Exception as e:
            # Fallback: send without parse_mode so a stray _ or * in text
            # doesn't silently swallow the alert.
            try:
                bot.send_message(admin_id, f"🚨 АЛЕРТ\n\n{text}")
            except Exception as e2:
                logger.error(f"Failed to send admin alert to {admin_id}: {e} / {e2}")

def check_and_alert():
    """Called every 5 min from uptime loop — alert if server down >5min or >3 complaints/hour."""
    # Server down check
    last = uptime_get_last_offline()
    if last and last[1] == 0:
        down_since = last[0]
        down_secs = time.time() - down_since
        if down_secs >= 300:  # 5 min
            # Check we haven't already alerted recently
            conn = sqlite3.connect(DB_PATH); c = conn.cursor()
            c.execute("SELECT sent_at FROM notification_history WHERE notification_type='admin_alert_down' ORDER BY id DESC LIMIT 1")
            row = c.fetchone(); conn.close()
            if not row or (time.time() - dateutil.parser.isoparse(row[0]).timestamp()) > 1800:
                admin_alert(f"⚠️ Сервер недоступен уже {int(down_secs/60)} мин!\nUptime за 24ч: {uptime_get_percent(24)}%")
                conn = sqlite3.connect(DB_PATH); c = conn.cursor()
                c.execute("INSERT INTO notification_history (telegram_id, notification_type, sent_at) VALUES (?,?,?)",
                          (0, "admin_alert_down", datetime.datetime.now(timezone.utc).isoformat()))
                conn.commit(); conn.close()
    # Complaint spike check
    complaints_1h = complaint_count_recent(1)
    if complaints_1h >= 3:
        conn = sqlite3.connect(DB_PATH); c = conn.cursor()
        c.execute("SELECT sent_at FROM notification_history WHERE notification_type='admin_alert_complaints' ORDER BY id DESC LIMIT 1")
        row = c.fetchone(); conn.close()
        if not row or (time.time() - dateutil.parser.isoparse(row[0]).timestamp()) > 3600:
            admin_alert(f"📈 Всплеск жалоб: {complaints_1h} за последний час!\nПроверьте статус сервера.")
            conn = sqlite3.connect(DB_PATH); c = conn.cursor()
            c.execute("INSERT INTO notification_history (telegram_id, notification_type, sent_at) VALUES (?,?,?)",
                      (0, "admin_alert_complaints", datetime.datetime.now(timezone.utc).isoformat()))
            conn.commit(); conn.close()



# #11: Channel-subscription gate (Telegram ChatMember check)
# ============================================================
REQUIRED_CHANNEL_ID = None  # set to e.g. -1001234567890 to enable gate
REQUIRED_CHANNEL_USERNAME = None  # set to "@mosaicvpn" to require subscription

def is_user_subscribed_to_channel(telegram_id):
    """Return True if no channel configured OR user is subscribed."""
    if not REQUIRED_CHANNEL_ID and not REQUIRED_CHANNEL_USERNAME:
        return True
    try:
        if REQUIRED_CHANNEL_USERNAME:
            chat = bot.get_chat(REQUIRED_CHANNEL_USERNAME)
        else:
            chat = bot.get_chat(REQUIRED_CHANNEL_ID)
        member = bot.get_chat_member(chat.id, telegram_id)
        return member.status in ["member", "administrator", "creator"]
    except Exception as e:
        logger.warning(f"Channel sub check failed for {telegram_id}: {e}")
        return True  # fail-open to avoid locking users out


# ============================================================
# #7: Admin panel helpers
# ============================================================
def admin_stats():
    """Return dict with global bot stats."""
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM users"); total_users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM invoices WHERE status='paid'"); paid_invoices = c.fetchone()[0]
    c.execute("SELECT COALESCE(SUM(amount),0) FROM invoices WHERE status='paid'"); total_revenue = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM tickets WHERE status='open'"); open_tickets = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM referral_stats WHERE paid>0"); active_referrers = c.fetchone()[0]
    avgr = rating_get_average()
    # Complaints in last 24h
    c.execute("""SELECT COUNT(*) FROM complaints
                 WHERE datetime(created_at) >= datetime(?, 'unixepoch')""", (time.time() - 86400,))
    complaints_24h = c.fetchone()[0]
    conn.close()
    return {
        "total_users": total_users,
        "paid_invoices": paid_invoices,
        "total_revenue": total_revenue,
        "open_tickets": open_tickets,
        "active_referrers": active_referrers,
        "rating_avg": avgr["avg"],
        "rating_count": avgr["count"],
        "uptime_24h": uptime_get_percent(24),
        "uptime_7d": uptime_get_percent(168),
        "complaints_24h": complaints_24h,
    }

def admin_top_users(limit=10):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("""SELECT u.telegram_id, u.username, COUNT(i.invoice_id) as paid_count,
                 COALESCE(SUM(i.amount),0) as total_paid
                 FROM users u LEFT JOIN invoices i ON u.telegram_id=i.telegram_id AND i.status='paid'
                 GROUP BY u.telegram_id ORDER BY total_paid DESC LIMIT ?""", (limit,))
    rows = c.fetchall(); conn.close()
    return rows


# Telegram Bot Handlers
def get_main_menu(lang):
    markup = types.ReplyKeyboardMarkup(resize_keyboard=True)
    t = MESSAGES[lang]
    markup.row(t["menu_buy"], t["menu_profile"])
    markup.row(t["menu_tariffs"], t["menu_instructions"])
    markup.row(t["menu_lang"], t["menu_proxies"])
    markup.row(t["menu_referral"], t["menu_support"])
    markup.row(t["menu_status"])
    return markup

@bot.message_handler(commands=["start"])
def send_welcome(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    
    referrer_id = None
    args = message.text.split()
    if len(args) > 1:
        ref_param = args[1]
        if ref_param.startswith("ref_"):
            try:
                referrer_id = int(ref_param[4:])
            except ValueError:
                pass
        elif ref_param.isdigit():
            referrer_id = int(ref_param)
            
        if referrer_id:
            if referrer_id == telegram_id:
                referrer_id = None
            else:
                ref_check = get_user(referrer_id)
                if not ref_check:
                    referrer_id = None
    
    if not db_user:
        # Detect language
        user_lang = message.from_user.language_code
        lang = "ru" if user_lang and user_lang.lower().startswith("ru") else "en"
        t = MESSAGES[lang]

        # #11: Trial gating — require channel subscription
        if not is_user_subscribed_to_channel(telegram_id):
            channel_url = f"t.me/{REQUIRED_CHANNEL_USERNAME[1:]}" if REQUIRED_CHANNEL_USERNAME else ""
            if lang == "ru":
                gate_text = (
                    "🔔 Чтобы получить бесплатный пробный доступ — подпишитесь на наш канал!\n\n"
                    f"👉 @{REQUIRED_CHANNEL_USERNAME[1:] if REQUIRED_CHANNEL_USERNAME else 'mosaicvpn'}\n\n"
                    "После подписки нажмите «Проверить» — триал активируется автоматически."
                )
            else:
                gate_text = (
                    "🔔 To get a free trial — subscribe to our channel!\n\n"
                    f"👉 @{REQUIRED_CHANNEL_USERNAME[1:] if REQUIRED_CHANNEL_USERNAME else 'mosaicvpn'}\n\n"
                    "After subscribing press \"Check\" — your trial will activate automatically."
                )
            markup = types.InlineKeyboardMarkup()
            if REQUIRED_CHANNEL_USERNAME:
                markup.row(types.InlineKeyboardButton(f"📢 {REQUIRED_CHANNEL_USERNAME}", url=f"https://{channel_url}"))
            markup.row(types.InlineKeyboardButton("✅ Проверить" if lang == "ru" else "✅ Check", callback_data="check_sub"))
            bot.send_message(telegram_id, gate_text, reply_markup=markup, parse_mode="Markdown")
            return
        
        # Provision a 3-day free trial user
        username = f"tg_{telegram_id}"
        created = api_create_user(username, 3, telegram_id)
        if created:
            short_uuid = created.get("shortUuid")
        else:
            existing = api_get_user(username)
            short_uuid = existing.get("shortUuid") if existing else ""
        
        save_user(telegram_id, username, short_uuid, lang, 1, referrer_id) # trial_used = 1
        db_user = {"username": username, "short_uuid": short_uuid, "language": lang, "trial_used": 1, "referrer_id": referrer_id}
        
        if referrer_id:
            # #1: Track "joined" stat + "click" stat
            ref_stats_incr(referrer_id, "clicks", by=1)
            ref_stats_incr(referrer_id, "joined", by=1)
            ref_lang = get_user_lang(referrer_id)
            if ref_lang == "ru":
                ref_welcome_text = "Ваш друг присоединился к Mosaic! 🎁 Когда он оформит подписку — вы оба получите бонус."
            else:
                ref_welcome_text = "Your friend has joined Mosaic! 🎁 When they purchase a subscription — you both will get a bonus."
            try:
                bot.send_message(referrer_id, ref_welcome_text)
            except Exception as e:
                logger.error(f"Failed to send referral join message to {referrer_id}: {e}")
                
    elif not db_user.get("short_uuid"):
        username = db_user["username"]
        existing = api_get_user(username)
        if existing:
            db_user["short_uuid"] = existing.get("shortUuid")
            save_user(telegram_id, username, db_user["short_uuid"], db_user["language"], db_user["trial_used"], db_user.get("referrer_id"))
    
    lang = db_user["language"]
    t = MESSAGES[lang]
    
    username = db_user["username"]
    short_uuid = db_user["short_uuid"]
    
    user_data = api_get_user(username)
    if user_data:
        expire_at_raw = user_data.get("expireAt")
        try:
            expire_dt = dateutil.parser.isoparse(expire_at_raw)
            expire_date = expire_dt.strftime("%Y-%m-%d")
            now = datetime.datetime.now(datetime.timezone.utc)
            days_left = (expire_dt - now).days
            if days_left < 0: days_left = 0
        except Exception:
            expire_date = expire_at_raw
            days_left = 0
            
        sub_url = f"https://sub.zxc1x1.ru/{short_uuid}"
        
        # Combine Welcome and Profile message for first start
        welcome_text = t["welcome"]
        profile_text = (
            "\n\n👤 **Ваш Профиль подписки:**\n"
            "• **Имя:** `{username}`\n"
            "• **Баланс:** `{balance} руб.`\n"
            "• **Действует до:** `{expire_date}` ({days} дн.)\n\n"
            "🔗 **Ваша ссылка на подписку (Атлас):**\n"
            "`{sub_url}`"
        ) if lang == "ru" else (
            "\n\n👤 **Your Subscription Profile:**\n"
            "• **Username:** `{username}`\n"
            "• **Balance:** `{balance} RUB`\n"
            "• **Expires:** `{expire_date}` ({days} days)\n\n"
            "🔗 **Your Subscription Link (Atlas):**\n"
            "`{sub_url}`"
        )
        
        full_text = welcome_text + profile_text.format(
            username=username,
            balance=days_left,
            days=days_left,
            expire_date=expire_date,
            sub_url=sub_url
        )
        
        markup = types.InlineKeyboardMarkup()
        markup.add(types.InlineKeyboardButton("🗺 Web Map" if lang == 'en' else "🗺 Открыть веб-карту", url=sub_url))
        markup.add(types.InlineKeyboardButton("⚡ Бесплатные прокси" if lang == 'ru' else "⚡ Free Proxies", callback_data="proxy_all"))
        
        bot.send_message(message.chat.id, full_text, parse_mode="Markdown", reply_markup=markup)
        bot.send_message(message.chat.id, "Вы можете управлять аккаунтом с помощью меню ниже:" if lang == "ru" else "You can manage your account using the menu below:", reply_markup=get_main_menu(lang))
    else:
        bot.send_message(message.chat.id, t["welcome"], parse_mode="Markdown", reply_markup=get_main_menu(lang))

@bot.message_handler(commands=["link"])
def issue_link_code_command(message):
    """Show a single-use code the user types into the desktop/mobile app."""
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"

    if not db_user:
        bot.send_message(
            telegram_id,
            "Сначала нажмите /start, чтобы создать аккаунт." if lang == "ru"
            else "Press /start first to create an account.")
        return

    try:
        code, expires = issue_link_code(
            telegram_id, db_user.get("username"), db_user.get("short_uuid"))
    except Exception as exc:
        logging.error("issue_link_code failed for %s: %s", telegram_id, exc)
        bot.send_message(
            telegram_id,
            "Не удалось создать код, попробуйте позже." if lang == "ru"
            else "Could not create a code, please try again later.")
        return

    minutes = LINK_CODE_TTL_MINUTES
    if lang == "ru":
        text = (f"Код для входа в приложение:\n\n<code>{code}</code>\n\n"
                f"Введите его в приложении в разделе «Кабинет».\n"
                f"Код действует {minutes} минут и работает один раз.")
    else:
        text = (f"Your app sign-in code:\n\n<code>{code}</code>\n\n"
                f"Enter it in the app under \"Account\".\n"
                f"Valid for {minutes} minutes, single use.")
    bot.send_message(telegram_id, text, parse_mode="HTML")


@bot.message_handler(commands=["support"])
def show_support(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.send_message(message.chat.id, MESSAGES[lang]["support"], parse_mode="Markdown")

@bot.message_handler(commands=["buy"])
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_buy"], MESSAGES["en"]["menu_buy"]])
def buy_subscription_menu(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    send_buy_menu(telegram_id, lang)

@bot.message_handler(commands=["profile"])
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_profile"], MESSAGES["en"]["menu_profile"]])
def show_profile(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    t = MESSAGES[lang]
    
    if db_user:
        username = db_user["username"]
        if not db_user.get("short_uuid"):
            existing = api_get_user(username)
            if existing:
                db_user["short_uuid"] = existing.get("shortUuid")
                save_user(telegram_id, username, db_user["short_uuid"], lang, db_user["trial_used"])
        short_uuid = db_user["short_uuid"]
        
        user_data = api_get_user(username)
        if user_data:
            expire_at_raw = user_data.get("expireAt")
            try:
                expire_dt = dateutil.parser.isoparse(expire_at_raw)
                expire_date = expire_dt.strftime("%Y-%m-%d")
                now = datetime.datetime.now(datetime.timezone.utc)
                days_left = (expire_dt - now).days
                if days_left < 0: days_left = 0
            except Exception:
                expire_date = expire_at_raw
                days_left = 0
                
            sub_url = f"https://sub.zxc1x1.ru/{short_uuid}"
            
            # #1: Referral stats block
            ref_stats = ref_stats_get(telegram_id)
            referrer_of = db_user.get("referrer_id")
            
            if lang == "ru":
                ref_block = (
                    f"\n\n📊 **Реферальная статистика:**\n"
                    f"👥 Приглашено: *{ref_stats['joined']}*\n"
                    f"💳 Оплатили: *{ref_stats['paid']}*\n"
                    f"🎁 Бонусных дней заработано: *{ref_stats['bonus_days_earned']}*\n"
                )
                if referrer_of:
                    ref_block += f"🔗 Вы пришли по приглашению пользователя `{referrer_of}`\n"
            else:
                ref_block = (
                    f"\n\n📊 **Referral Statistics:**\n"
                    f"👥 Invited: *{ref_stats['joined']}*\n"
                    f"💳 Paid: *{ref_stats['paid']}*\n"
                    f"🎁 Bonus days earned: *{ref_stats['bonus_days_earned']}*\n"
                )
                if referrer_of:
                    ref_block += f"🔗 You joined via invitation from user `{referrer_of}`\n"
            
            # #3: Server status indicator
            srv_status = get_server_status(short_uuid)
            if srv_status["online"]:
                srv_block = "\n✅ Сервер: онлайн" if lang == "ru" else "\n✅ Server: online"
            else:
                srv_block = "\n⚠️ Сервер: проверка..." if lang == "ru" else "\n⚠️ Server: checking..."
            
            account_id_line = (
                f"\n\nID аккаунта: `{telegram_id}`"
                if lang == "ru" else f"\n\nAccount ID: `{telegram_id}`"
            )
            if user_data.get("status") == "ACTIVE" and days_left > 0:
                text = t["profile_active"].format(
                    username=username,
                    balance=days_left, # 1 ruble per day
                    days=days_left,
                    expire_date=expire_date,
                    sub_url=sub_url
                ) + account_id_line + ref_block + srv_block
            else:
                text = t["profile_inactive"].format(
                    username=username,
                    expire_date=expire_date
                ) + account_id_line + ref_block + srv_block
                
            markup = types.InlineKeyboardMarkup()
            markup.add(types.InlineKeyboardButton("🗺 Web Map" if lang == 'en' else "🗺 Открыть веб-карту", url=sub_url))
            markup.add(types.InlineKeyboardButton("⚡ Бесплатные прокси" if lang == 'ru' else "⚡ Free Proxies", callback_data="proxy_all"))
            bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)
            return
            
    bot.send_message(telegram_id, t["profile_not_found"], parse_mode="Markdown")

@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_tariffs"], MESSAGES["en"]["menu_tariffs"]])
def show_tariffs(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.send_message(message.chat.id, MESSAGES[lang]["tariffs"], parse_mode="Markdown")

@bot.message_handler(commands=["instructions"])
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_instructions"], MESSAGES["en"]["menu_instructions"]])
def show_instructions(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.send_message(message.chat.id, MESSAGES[lang]["instructions"], parse_mode="Markdown", disable_web_page_preview=True)

@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_lang"], MESSAGES["en"]["menu_lang"]])
def show_language_selector(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    
    markup = types.InlineKeyboardMarkup()
    markup.row(
        types.InlineKeyboardButton("🇷🇺 Русский", callback_data="lang_ru"),
        types.InlineKeyboardButton("🇬🇧 English", callback_data="lang_en")
    )
    bot.send_message(message.chat.id, MESSAGES[lang]["lang_title"], reply_markup=markup)

@bot.message_handler(commands=["broadcast"])
def handle_broadcast(message):
    telegram_id = message.chat.id
    if not is_admin(telegram_id):
        return
        
    parts = message.text.split(" ", 1)
    if len(parts) < 2:
        bot.send_message(telegram_id, "Usage: `/broadcast <message>`", parse_mode="Markdown")
        return
        
    broadcast_msg = parts[1]
    users = get_all_tg_users()
    
    count = 0
    fail_parse = 0
    fail_429 = 0
    for uid in users:
        try:
            bot.send_message(uid, broadcast_msg, parse_mode="Markdown")
            count += 1
        except Exception as e:
            err_str = str(e)
            if "429" in err_str or "Too Many Requests" in err_str:
                # Telegram rate limit — wait and retry once
                retry_after = 1
                import re as _re
                m = _re.search(r"retry after (\d+)", err_str, _re.I)
                if m:
                    retry_after = int(m.group(1))
                logger.warning(f"429 rate limit broadcasting to {uid}; retrying in {retry_after}s")
                time.sleep(retry_after + 1)
                try:
                    bot.send_message(uid, broadcast_msg, parse_mode="Markdown")
                    count += 1
                except Exception as e2:
                    # Fallback: send without parse_mode so broken Markdown doesn't lose the message
                    if "parse" in str(e2).lower() or "entity" in str(e2).lower():
                        try:
                            bot.send_message(uid, broadcast_msg)
                            count += 1
                        except Exception:
                            fail_parse += 1
                    else:
                        fail_429 += 1
            elif "parse" in err_str.lower() or "entity" in err_str.lower():
                # Markdown parse error — retry without parse_mode
                try:
                    bot.send_message(uid, broadcast_msg)
                    count += 1
                except Exception:
                    fail_parse += 1
            else:
                logger.error(f"Failed to send broadcast to {uid}: {e}")
        time.sleep(0.05)  # ~20 msg/sec — stay under Telegram's global limit (~30/sec)
    
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    summary = MESSAGES[lang]["broadcast_sent"].format(count=count)
    if fail_parse or fail_429:
        summary += f"\n⚠️ Failed: {fail_parse} (parse), {fail_429} (rate limit)"
    bot.send_message(telegram_id, summary)

def send_buy_menu(chat_id, lang):
    t = MESSAGES[lang]
    markup = types.InlineKeyboardMarkup(row_width=1)
    for days, pkg in PACKAGES.items():
        text = pkg[lang]
        markup.add(types.InlineKeyboardButton(text, callback_data=f"buy_{days}"))
    markup.add(types.InlineKeyboardButton(t["custom_button"], callback_data="buy_custom"))
    bot.send_message(chat_id, t["buy_title"] + "\n\nОплата доступна через Lava: СБП или банковскую карту." if lang == "ru" else t["buy_title"] + "\n\nPay securely via Lava using SBP or bank card.", parse_mode="Markdown", reply_markup=markup)

def send_buy_discount_menu(chat_id, lang):
    t = MESSAGES[lang]
    markup = types.InlineKeyboardMarkup(row_width=1)
    for days, pkg in PACKAGES.items():
        disc_price = pkg["price_usdt"] / 2.0
        if lang == "ru":
            promo_text = f"🏷 {days} дней подписки — {disc_price:.2f} USDT (вместо {pkg['price_usdt']:.2f} USDT)"
        else:
            promo_text = f"🏷 {days} subscription days — {disc_price:.2f} USDT (was {pkg['price_usdt']:.2f} USDT)"
        markup.add(types.InlineKeyboardButton(promo_text, callback_data=f"buy_discount_{days}"))
    text = (
        "🏷 **Выберите пакет со скидкой 50%:**\n\n"
        "Предложение действует 24 часа. Скидка применится к вашему счету автоматически."
        if lang == "ru" else
        "🏷 **Select a package with 50% discount:**\n\n"
        "Offer valid for 24 hours. Discount will apply automatically."
    )
    bot.send_message(chat_id, text, parse_mode="Markdown", reply_markup=markup)

@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_referral"], MESSAGES["en"]["menu_referral"]])
@bot.message_handler(commands=["referral", "ref"])
def show_referral_promo(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    
    markup = types.InlineKeyboardMarkup()
    markup.row(types.InlineKeyboardButton("🔗 Получить ссылку" if lang == "ru" else "🔗 Get link", callback_data="ref_link"))
    markup.row(types.InlineKeyboardButton("🏆 Лидерборд" if lang == "ru" else "🏆 Leaderboard", callback_data="ref_leaderboard"))
    markup.row(types.InlineKeyboardButton("💎 Тарифы" if lang == "ru" else "💎 Tariffs", callback_data="show_tariffs"))
    
    bot.send_message(telegram_id, MESSAGES[lang]["referral_promo"], parse_mode="Markdown", reply_markup=markup)

@bot.callback_query_handler(func=lambda call: call.data == "ref_link")
def handle_ref_link_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    send_ref_link(telegram_id, lang)

def send_ref_link(telegram_id, lang):
    bot_username = bot.get_me().username
    ref_link_url = f"https://t.me/{bot_username}?start=ref_{telegram_id}"
    t = MESSAGES[lang]
    text = t["referral_link_text"].format(link=ref_link_url)
    bot.send_message(telegram_id, text, parse_mode="Markdown")

# ============================================================
# #8: Referral leaderboard callback
# ============================================================
@bot.callback_query_handler(func=lambda call: call.data == "ref_leaderboard")
def handle_ref_leaderboard(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    top = ref_leaderboard_top(10)
    if not top or all(r[1] == 0 and r[2] == 0 for r in top):
        text = "🏆 **Лидерборд пока пуст**\n\nНикто ещё не пригласил друзей. Будь первым!" if lang == "ru" else "🏆 **Leaderboard is empty**\n\nNobody has invited friends yet. Be the first!"
    else:
        if lang == "ru":
            text = "🏆 **Топ-10 рефералов Mosaic VPN**\n\n"
            medals = ["🥇", "🥈", "🥉"]
            for i, (rid, joined, paid, bonus) in enumerate(top):
                if joined == 0 and paid == 0:
                    continue
                medal = medals[i] if i < 3 else f"`{i+1}.`"
                text += f"{medal} ID `{rid}` — 👥 {joined} | 💳 {paid} | 🎁 {bonus} дн.\n"
            text += "\nПриглашай друзей и поднимайся в топ!"
        else:
            text = "🏆 **Top-10 Mosaic VPN Referrers**\n\n"
            medals = ["🥇", "🥈", "🥉"]
            for i, (rid, joined, paid, bonus) in enumerate(top):
                if joined == 0 and paid == 0:
                    continue
                medal = medals[i] if i < 3 else f"`{i+1}.`"
                text += f"{medal} ID `{rid}` — 👥 {joined} | 💳 {paid} | 🎁 {bonus}d\n"
            text += "\nInvite friends and climb the leaderboard!"
    bot.send_message(telegram_id, text, parse_mode="Markdown")

# ============================================================
# #11: Channel subscription check callback
# ============================================================
@bot.callback_query_handler(func=lambda call: call.data == "check_sub")
def handle_check_sub(call):
    telegram_id = call.message.chat.id
    is_ru = call.from_user.language_code and call.from_user.language_code.startswith("ru")
    if is_user_subscribed_to_channel(telegram_id):
        bot.answer_callback_query(call.id, "✅ Подписка подтверждена!" if is_ru else "✅ Subscription confirmed!")
        bot.send_message(telegram_id, "🎉 Отлично! Активируем ваш триал..." if is_ru else "🎉 Great! Activating your trial...")
        class FakeMsg:
            def __init__(self, tid, uid, text, lang_code):
                self.chat = type("obj", (object,), {"id": tid})()
                self.from_user = type("obj", (object,), {"id": uid, "language_code": lang_code})()
                self.text = text
        fake = FakeMsg(telegram_id, call.from_user.id, "/start", call.from_user.language_code)
        send_welcome(fake)
    else:
        bot.answer_callback_query(call.id, "❌ Вы не подписаны на канал" if is_ru else "❌ You haven't subscribed", show_alert=True)

# ============================================================
# #9: 1-tap renew callback
# ============================================================
@bot.callback_query_handler(func=lambda call: call.data.startswith("renew_"))
def handle_renew_1tap(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    days_str = call.data.split("_", 1)[1]
    try:
        days = int(days_str)
    except ValueError:
        days = 30
    pkg = PACKAGES.get(days, PACKAGES.get(30))
    bot.send_message(telegram_id, MESSAGES[lang]["buy_title"] + MESSAGES[lang]["p2p_info"],
                     parse_mode="Markdown", reply_markup=types.InlineKeyboardMarkup().add(
                         types.InlineKeyboardButton(pkg[lang], callback_data=f"buy_{days}")))

# ============================================================
# #13: Service status page (uptime % + complaints)
# ============================================================
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_status"], MESSAGES["en"]["menu_status"]])
@bot.message_handler(commands=["status"])
def show_service_status(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    up_24h = uptime_get_percent(24)
    up_7d = uptime_get_percent(168)
    avg_rating = rating_get_average()
    # Determine status emoji
    if up_24h >= 99:
        status_emoji = "🟢"
        status_text = "Все системы в норме" if lang == "ru" else "All systems operational"
    elif up_24h >= 90:
        status_emoji = "🟡"
        status_text = "Возможны перебои" if lang == "ru" else "Minor issues possible"
    else:
        status_emoji = "🔴"
        status_text = "Сервер недоступен" if lang == "ru" else "Server down"
    text = (
        f"📊 **Статус сервиса**\n\n"
        f"{status_emoji} **{status_text}**\n\n"
        f"⏱ Uptime 24ч: **{up_24h}%**\n"
        f"⏱ Uptime 7д: **{up_7d}%**\n"
        f"⭐ Средняя оценка: **{avg_rating['avg'] or '—'}** ({avg_rating['count']} отзывов)\n\n"
        f"_Обновляется каждые 5 минут_"
    ) if lang == "ru" else (
        f"📊 **Service Status**\n\n"
        f"{status_emoji} **{status_text}**\n\n"
        f"⏱ Uptime 24h: **{up_24h}%**\n"
        f"⏱ Uptime 7d: **{up_7d}%**\n"
        f"⭐ Average rating: **{avg_rating['avg'] or '—'}** ({avg_rating['count']} reviews)\n\n"
        f"_Updated every 5 minutes_"
    )
    markup = types.InlineKeyboardMarkup(row_width=1)
    markup.add(types.InlineKeyboardButton(
        "⚠️ Сообщить о проблеме" if lang == "ru" else "⚠️ Report an issue",
        callback_data="report_issue"))
    bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)


@bot.callback_query_handler(func=lambda call: call.data == "report_issue")
def handle_report_issue(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    if not rate_limit_check(telegram_id, "ticket"):
        bot.send_message(telegram_id, "⏳ Слишком много запросов. Попробуйте позже." if lang == "ru" else "⏳ Too many requests. Try later.")
        return
    markup = types.InlineKeyboardMarkup(row_width=1)
    categories_ru = [("🌐 Не работает подключение", "cat_connection"),
                     ("🐢 Низкая скорость", "cat_speed"),
                     ("📱 Не подключается на телефоне", "cat_mobile"),
                     ("💻 Не подключается на ПК", "cat_pc"),
                     ("❓ Другое", "cat_other")]
    categories_en = [("🌐 Connection not working", "cat_connection"),
                     ("🐢 Slow speed", "cat_speed"),
                     ("📱 Mobile connection issue", "cat_mobile"),
                     ("💻 Desktop connection issue", "cat_pc"),
                     ("❓ Other", "cat_other")]
    cats = categories_ru if lang == "ru" else categories_en
    for label, cd in cats:
        markup.add(types.InlineKeyboardButton(label, callback_data=cd))
    markup.add(types.InlineKeyboardButton("🔙 Назад" if lang == "ru" else "🔙 Back", callback_data="back_to_status"))
    text = ("⚠️ **Что случилось?**\n\nВыберите категорию проблемы — мы проверим сразу."
            if lang == "ru"
            else "⚠️ **What happened?**\n\nSelect a problem category — we'll check right away.")
    bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)


@bot.callback_query_handler(func=lambda call: call.data.startswith("cat_"))
def handle_complaint_category(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    category_map = {
        "cat_connection": "Подключение не работает" if lang == "ru" else "Connection not working",
        "cat_speed": "Низкая скорость" if lang == "ru" else "Slow speed",
        "cat_mobile": "Проблема на телефоне" if lang == "ru" else "Mobile issue",
        "cat_pc": "Проблема на ПК" if lang == "ru" else "PC issue",
        "cat_other": "Другое" if lang == "ru" else "Other",
    }
    category = category_map.get(call.data, call.data)
    complaint_id = complaint_create(telegram_id, category)
    # Forward to admin
    try:
        user_link = f"tg://user?id={telegram_id}"
        for admin_id in ADMIN_IDS:
            bot.send_message(admin_id,
                f"⚠️ **Жалоба #{complaint_id}**\n"
                f"📂 Категория: {category}\n"
                f"👤 Юзер: {user_link}\n"
                f"🕐 {datetime.datetime.now(timezone.utc).strftime('%H:%M UTC')}",
                parse_mode="Markdown")
    except Exception as e:
        logger.error(f"Failed to forward complaint #{complaint_id}: {e}")
    text = (f"✅ Жалоба #{complaint_id} зарегистрирована.\n"
            f"Категория: {category}\n\n"
            f"Мы уже получили уведомление и проверяем. Спасибо!" if lang == "ru"
            else f"✅ Complaint #{complaint_id} registered.\n"
            f"Category: {category}\n\n"
            f"We've been notified and are checking. Thank you!")
    bot.send_message(telegram_id, text)


@bot.callback_query_handler(func=lambda call: call.data == "back_to_status")
def handle_back_to_status(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    up_24h = uptime_get_percent(24)
    up_7d = uptime_get_percent(168)
    avg_rating = rating_get_average()
    if up_24h >= 99:
        status_emoji = "🟢"
        status_text = "Все системы в норме" if lang == "ru" else "All systems operational"
    elif up_24h >= 90:
        status_emoji = "🟡"
        status_text = "Возможны перебои" if lang == "ru" else "Minor issues possible"
    else:
        status_emoji = "🔴"
        status_text = "Сервер недоступен" if lang == "ru" else "Server down"
    text = (
        f"📊 **Статус сервиса**\n\n"
        f"{status_emoji} **{status_text}**\n\n"
        f"⏱ Uptime 24ч: **{up_24h}%**\n"
        f"⏱ Uptime 7д: **{up_7d}%**\n"
        f"⭐ Средняя оценка: **{avg_rating['avg'] or '—'}** ({avg_rating['count']} отзывов)\n\n"
        f"_Обновляется каждые 5 минут_"
    ) if lang == "ru" else (
        f"📊 **Service Status**\n\n"
        f"{status_emoji} **{status_text}**\n\n"
        f"⏱ Uptime 24h: **{up_24h}%**\n"
        f"⏱ Uptime 7d: **{up_7d}%**\n"
        f"⭐ Average rating: **{avg_rating['avg'] or '—'}** ({avg_rating['count']} reviews)\n\n"
        f"_Updated every 5 minutes_"
    )
    markup = types.InlineKeyboardMarkup(row_width=1)
    markup.add(types.InlineKeyboardButton(
        "⚠️ Сообщить о проблеме" if lang == "ru" else "⚠️ Report an issue",
        callback_data="report_issue"))
    bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)


# ============================================================
# #10: Support ticket flow
# ============================================================
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_support"], MESSAGES["en"]["menu_support"]])
@bot.message_handler(commands=["support"])
def show_support_menu(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    if not rate_limit_check(telegram_id, "ticket"):
        bot.send_message(telegram_id, "⏳ Слишком много запросов. Попробуйте позже." if lang == "ru" else "⏳ Too many requests. Try later.")
        return
    markup = types.InlineKeyboardMarkup(row_width=1)
    markup.add(types.InlineKeyboardButton("📝 Создать обращение" if lang == "ru" else "📝 Create ticket", callback_data="ticket_new"))
    markup.add(types.InlineKeyboardButton("📋 Мои обращения" if lang == "ru" else "📋 My tickets", callback_data="ticket_list"))
    markup.add(types.InlineKeyboardButton("❓ FAQ" if lang == "ru" else "❓ FAQ", callback_data="faq"))
    bot.send_message(telegram_id, MESSAGES[lang]["support_prompt"], parse_mode="Markdown", reply_markup=markup)

@bot.callback_query_handler(func=lambda call: call.data == "faq")
def handle_faq(call):
    bot.answer_callback_query(call.id)
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    faq_text = (
        "❓ **FAQ Mosaic VPN**\n\n"
        "**Q: Как подключиться?**\n"
        "A: Откройте профиль → скопируйте ссылку подписки → вставьте в приложение (v2RayTun, Hiddify, sing-box).\n\n"
        "**Q: Сколько устройств?**\n"
        "A: До 5 устройств, привязка по HWID.\n\n"
        "**Q: Как продлить?**\n"
        "A: Меню → 🛒 Купить → выберите тариф.\n\n"
        "**Q: Рефералка?**\n"
        "A: 🎁 Пригласить друга → друг оплачивает → вы оба получаете бонусные дни.\n\n"
        "**Q: Поддержка 24/7?**\n"
        "A: Да! Создайте обращение через 🎧 Поддержка."
    ) if lang == "ru" else (
        "❓ **Mosaic VPN FAQ**\n\n"
        "**Q: How to connect?**\n"
        "A: Open profile → copy subscription link → paste into app (v2RayTun, Hiddify, sing-box).\n\n"
        "**Q: How many devices?**\n"
        "A: Up to 5 devices, HWID-bound.\n\n"
        "**Q: How to renew?**\n"
        "A: Menu → 🛒 Buy → select a plan.\n\n"
        "**Q: Referral program?**\n"
        "A: 🎁 Invite a friend → they purchase → you both get bonus days.\n\n"
        "**Q: 24/7 support?**\n"
        "A: Yes! Create a ticket via 🎧 Support."
    )
    bot.send_message(telegram_id, faq_text, parse_mode="Markdown")

@bot.callback_query_handler(func=lambda call: call.data == "ticket_new")
def handle_ticket_new(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    msg = bot.send_message(telegram_id,
        "📝 Опишите вашу проблему одним сообщением:" if lang == "ru" else "📝 Describe your issue in one message:")
    bot.register_next_step_handler(msg, process_ticket_message)

def process_ticket_message(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    subject = message.text[:500] if message.text else "(no text)"
    ticket_id = ticket_create(telegram_id, subject)
    ticket_add_message(ticket_id, "user", subject)
    # Forward to admin
    admin_text = (
        f"🎫 **Новый тикет #{ticket_id}**\n"
        f"👤 Юзер: `{telegram_id}`\n"
        f"📝 Тема: {subject[:200]}"
    )
    try:
        for admin_id in ADMIN_IDS:
            bot.send_message(admin_id, admin_text, parse_mode="Markdown",
                             reply_markup=types.InlineKeyboardMarkup().add(
                                 types.InlineKeyboardButton("💬 Ответить" if lang == "ru" else "💬 Reply",
                                                            callback_data=f"admin_reply_{ticket_id}")))
    except Exception as e:
        logger.error(f"Failed to forward ticket #{ticket_id} to admin: {e}")
    bot.send_message(telegram_id,
        f"✅ Обращение #{ticket_id} создано. Мы ответим в ближайшее время." if lang == "ru"
        else f"✅ Ticket #{ticket_id} created. We'll reply shortly.")

@bot.callback_query_handler(func=lambda call: call.data == "ticket_list")
def handle_ticket_list(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT id, subject, status, created_at FROM tickets WHERE telegram_id=? ORDER BY created_at DESC LIMIT 5",
              (telegram_id,))
    rows = c.fetchall(); conn.close()
    if not rows:
        bot.send_message(telegram_id, "📋 У вас нет обращений." if lang == "ru" else "📋 You have no tickets.")
        return
    text = "📋 **Ваши обращения:**\n\n" if lang == "ru" else "📋 **Your tickets:**\n\n"
    for tid, subj, status, created in rows:
        status_emoji = "🟢" if status == "open" else "🔴"
        text += f"{status_emoji} #{tid} — {subj[:60]}{'…' if len(subj)>60 else ''}\n"
    bot.send_message(telegram_id, text, parse_mode="Markdown")

@bot.callback_query_handler(func=lambda call: call.data.startswith("admin_reply_"))
def handle_admin_reply(call):
    admin_id = call.message.chat.id
    ticket_id = int(call.data.split("_")[2])
    bot.answer_callback_query(call.id)
    msg = bot.send_message(admin_id, f"💬 Напишите ответ для тикета #{ticket_id}:")
    bot.register_next_step_handler(msg, process_admin_reply, ticket_id=ticket_id)

def process_admin_reply(message, ticket_id=None):
    admin_id = message.chat.id
    reply_text = message.text[:2000]
    ticket_add_message(ticket_id, "admin", reply_text)
    # Find ticket owner
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("SELECT telegram_id FROM tickets WHERE id=?", (ticket_id,))
    row = c.fetchone(); conn.close()
    if row:
        owner_id = row[0]
        try:
            bot.send_message(owner_id,
                f"💬 **Ответ поддержки по обращению #{ticket_id}:**\n\n{reply_text}",
                parse_mode="Markdown",
                reply_markup=types.InlineKeyboardMarkup().add(
                    types.InlineKeyboardButton("✉️ Ответить" if True else "✉️ Reply",
                                               callback_data=f"ticket_new")))
        except Exception as e:
            logger.error(f"Failed to send reply to user {owner_id}: {e}")
    bot.send_message(admin_id, f"✅ Ответ отправлен для тикета #{ticket_id}")

# ============================================================
# #12: Rating flow (1-5 stars)
# ============================================================
@bot.callback_query_handler(func=lambda call: call.data.startswith("rate_"))
def handle_rating(call):
    telegram_id = call.message.chat.id
    rating = int(call.data.split("_")[1])
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    if not rate_limit_check(telegram_id, "rating"):
        bot.answer_callback_query(call.id, "⏳ Уже голосовали сегодня" if lang == "ru" else "⏳ Already voted today")
        return
    rating_save(telegram_id, rating)
    emoji_stars = "⭐" * rating
    bot.answer_callback_query(call.id, "✅ Спасибо за оценку!" if lang == "ru" else "✅ Thanks for rating!")
    bot.edit_message_reply_markup(call.message.chat.id, call.message.message_id, reply_markup=None)
    bot.send_message(telegram_id,
        f"Спасибо за оценку! {emoji_stars}\n\nЕсли хотите — оставьте комментарий текстом:" if lang == "ru"
        else f"Thank you for rating! {emoji_stars}\n\nLeave a text comment if you'd like:")
    bot.register_next_step_handler(call.message, process_rating_comment, rating=rating)

def process_rating_comment(message, rating=None):
    comment = message.text[:1000] if message.text else None
    if comment:
        conn = sqlite3.connect(DB_PATH); c = conn.cursor()
        c.execute("UPDATE user_ratings SET comment=? WHERE telegram_id=? AND rating=? ORDER BY created_at DESC LIMIT 1",
                  (comment, message.chat.id, rating))
        conn.commit(); conn.close()

# ============================================================
# #7: Enhanced admin panel
# ============================================================
@bot.message_handler(commands=["admin"])
@bot.message_handler(func=lambda m: m.text and m.text.startswith("/admin"))
def show_admin_panel(message):
    telegram_id = message.chat.id
    if telegram_id not in ADMIN_IDS:
        return
    stats = admin_stats()
    rating_str = f"{stats['rating_avg']:.1f}⭐ ({stats['rating_count']} оценок)" if stats['rating_avg'] else "—"
    text = (
        f"🔐 **Админ-панель Mosaic**\n\n"
        f"👥 Юзеров: `{stats['total_users']}`\n"
        f"💳 Оплаченных инвойсов: `{stats['paid_invoices']}`\n"
        f"💰 Выручка: `{stats['total_revenue']}` ₽\n"
        f"🎁 Активных рефереров: `{stats['active_referrers']}`\n"
        f"🎫 Открытых тикетов: `{stats['open_tickets']}`\n"
        f"⭐ Средний рейтинг: {rating_str}\n"
        f"📊 Uptime 24ч: `{stats['uptime_24h']}%` | 7д: `{stats['uptime_7d']}%`\n"
        f"⚠️ Жалоб за 24ч: `{stats['complaints_24h']}`\n\n"
        f"Команды:\n"
        f"`/broadcast <текст>` — рассылка\n"
        f"`/top` — топ-10 юзеров\n"
        f"`/promo gen <code> <days> <discount%> <max_uses>` — создать промокод\n"
        f"`/promo list` — список промокодов\n"
        f"`/tickets` — открытые тикеты\n"
    )
    bot.send_message(telegram_id, text, parse_mode="Markdown")

@bot.message_handler(commands=["top"])
def handle_admin_top(message):
    if message.chat.id not in ADMIN_IDS:
        return
    users = admin_top_users(10)
    text = "🏆 **Топ-10 юзеров по выручке:**\n\n"
    medals = ["🥇","🥈","🥉"]
    for i, (uid, uname, paid_count, total_paid) in enumerate(users):
        medal = medals[i] if i < 3 else f"`{i+1}.`"
        text += f"{medal} {uname or uid} — 💳 {paid_count} | 💰 {total_paid}₽\n"
    bot.send_message(message.chat.id, text, parse_mode="Markdown")

# ============================================================
# #2: Promo codes admin commands
# ============================================================
@bot.message_handler(func=lambda m: m.text and m.text.startswith("/promo"))
def handle_promo_admin(message):
    if message.chat.id not in ADMIN_IDS:
        return
    parts = message.text.split()
    if len(parts) < 2:
        bot.send_message(message.chat.id, "Использование:\n`/promo gen CODE DAYS DISCOUNT% MAX_USES`\n`/promo list`", parse_mode="Markdown")
        return
    sub = parts[1].lower()
    if sub == "gen":
        if len(parts) < 6:
            bot.send_message(message.chat.id, "Формат: `/promo gen SUMMER30 30 0 100`", parse_mode="Markdown")
            return
        code = parts[2]
        days = int(parts[3]) if parts[3].isdigit() else 0
        discount = int(parts[4].rstrip("%")) if parts[4].rstrip("%").isdigit() else 0
        max_uses = int(parts[5]) if parts[5].lstrip("-").isdigit() else -1
        ok = promo_create(code, days_bonus=days, discount_percent=discount, max_uses=max_uses, created_by=message.chat.id)
        if ok:
            bot.send_message(message.chat.id, f"✅ Промокод `{code}` создан: +{days} дн, скидка {discount}%, лимит {max_uses}", parse_mode="Markdown")
        else:
            bot.send_message(message.chat.id, f"❌ Промокод `{code}` уже существует", parse_mode="Markdown")
    elif sub == "list":
        conn = sqlite3.connect(DB_PATH); c = conn.cursor()
        c.execute("SELECT code, days_bonus, discount_percent, max_uses, used_count FROM promo_codes ORDER BY created_at DESC")
        rows = c.fetchall(); conn.close()
        if not rows:
            bot.send_message(message.chat.id, "Промокодов нет.")
            return
        text = "🎟 **Промокоды:**\n\n"
        for code, days, disc, mx, used in rows:
            lim = str(mx) if mx >= 0 else "∞"
            text += f"`{code}` — +{days}дн, {disc}%, исп: {used}/{lim}\n"
        bot.send_message(message.chat.id, text, parse_mode="Markdown")

@bot.message_handler(commands=["tickets"])
def handle_admin_tickets(message):
    if message.chat.id not in ADMIN_IDS:
        return
    tickets = ticket_list_open()
    if not tickets:
        bot.send_message(message.chat.id, "✅ Нет открытых тикетов.")
        return
    text = f"🎫 **Открытые тикеты ({len(tickets)}):**\n\n"
    for tid, tg_id, subj, created, uname in tickets:
        text += f"#{tid} — {uname or tg_id}: {subj[:80]}\n"
    text += "\nИспользуйте `/admin_reply_ID` чтобы ответить."
    bot.send_message(message.chat.id, text, parse_mode="Markdown")



@bot.callback_query_handler(func=lambda call: call.data == "show_tariffs")
def handle_show_tariffs_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    markup = types.InlineKeyboardMarkup(row_width=1)
    for days, pkg in PACKAGES.items():
        markup.add(types.InlineKeyboardButton(pkg[lang], callback_data=f"buy_{days}"))
    markup.add(types.InlineKeyboardButton(MESSAGES[lang]["custom_button"], callback_data="buy_custom"))
    bot.send_message(telegram_id, MESSAGES[lang]["tariffs"], parse_mode="Markdown", reply_markup=markup)

@bot.callback_query_handler(func=lambda call: call.data == "buy_subscription")
def handle_buy_subscription_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    send_buy_menu(telegram_id, lang)

@bot.callback_query_handler(func=lambda call: call.data == "buy_discount")
def handle_buy_discount_menu_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    send_buy_discount_menu(telegram_id, lang)

@bot.callback_query_handler(func=lambda call: call.data.startswith("buy_discount_"))
def handle_buy_discount_callback(call):
    try:
        days = int(call.data.split("_")[2])
        pkg = PACKAGES[days]
        amount = pkg["price_usdt"] / 2.0  # Скидка 50%
        months = pkg["months"]
        telegram_id = call.message.chat.id
        
        db_user = get_user(telegram_id)
        lang = db_user["language"] if db_user else "ru"
        t = MESSAGES[lang]
        
        bot.answer_callback_query(call.id, "..." if lang == 'en' else "Создаем счет со скидкой...")
        
        invoice_id, pay_url = create_cryptopay_invoice(amount, days)
        
        if invoice_id and pay_url:
            save_invoice(invoice_id, telegram_id, amount, months, days)
            text = (
                f"✅ **Скидка 50% применена!**\n\n"
                f"💳 **Счет на оплату готов!**\n\n"
                f"• **Товар:** Пополнение баланса на {days} дней (Акция)\n"
                f"• **Сумма:** {amount:.2f} USDT (вместо {pkg['price_usdt']:.2f} USDT)\n\n"
                f"Нажмите кнопку ниже, чтобы перейти к оплате через CryptoBot."
                if lang == "ru" else
                f"✅ **50% Discount Applied!**\n\n"
                f"💳 **Invoice is ready!**\n\n"
                f"• **Item:** {days} subscription days (Promo)\n"
                f"• **Price:** {amount:.2f} USDT (was {pkg['price_usdt']:.2f} USDT)\n\n"
                f"Click the button below to pay via CryptoBot."
            )
            
            markup = types.InlineKeyboardMarkup()
            markup.add(types.InlineKeyboardButton(t["pay_button"], url=pay_url))
            bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)
        else:
            bot.send_message(telegram_id, t["error_invoice"])
    except Exception as e:
        logger.error(f"Discount callback error: {e}")

def _send_lava_invoice_for_chat(telegram_id, amount, days, lang):
    invoice = create_lava_invoice("bot", telegram_id, amount, days, f"MosaicVPN: пополнение на {days} дней")
    save_lava_invoice(invoice["internal_id"], invoice["provider_id"], invoice["order_id"], telegram_id, amount, days, "bot")
    text = (f"💳 **Счёт на оплату готов**\n\nПополнение: **{days} дней**\nСумма: **{amount:.0f} ₽**\n\nПосле оплаты доступ обновится автоматически." if lang == "ru" else f"💳 **Invoice ready**\n\nTop-up: **{days} days**\nAmount: **{amount:.0f} RUB**\n\nYour access will update automatically after payment.")
    markup = types.InlineKeyboardMarkup()
    markup.add(types.InlineKeyboardButton(MESSAGES[lang]["lava_button"], url=invoice["payment_url"]))
    bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)


@bot.callback_query_handler(func=lambda call: call.data == "buy_custom")
def handle_buy_custom_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    bot.answer_callback_query(call.id)
    prompt = "Введите целое количество рублей от 1 до 100000. 1 ₽ = 1 день." if lang == "ru" else "Enter a whole RUB amount from 1 to 100000. 1 RUB = 1 day."
    msg = bot.send_message(telegram_id, prompt)
    bot.register_next_step_handler(msg, process_custom_lava_amount)


def process_custom_lava_amount(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    raw = (message.text or "").replace("₽", "").replace(" ", "").strip()
    try:
        amount = float(raw.replace(",", "."))
    except ValueError:
        bot.send_message(telegram_id, "Введите целое число рублей." if lang == "ru" else "Enter a whole RUB amount.")
        return
    if amount < 1 or amount > 100000 or amount != int(amount):
        bot.send_message(telegram_id, "Сумма должна быть целым числом от 1 до 100000 ₽." if lang == "ru" else "Amount must be a whole number from 1 to 100000 RUB.")
        return
    try:
        _send_lava_invoice_for_chat(telegram_id, amount, int(amount), lang)
    except (RuntimeError, ValueError) as exc:
        logger.error("Custom Lava invoice failed: %s", exc)
        bot.send_message(telegram_id, "Не удалось создать счёт. Попробуйте позже." if lang == "ru" else "Could not create the invoice. Please try again later.")


@bot.callback_query_handler(func=lambda call: call.data.startswith("buy_"))
def handle_buy_callback(call):
    try:
        days = int(call.data.split("_")[1])
        pkg = PACKAGES[days]
        telegram_id = call.message.chat.id
        db_user = get_user(telegram_id)
        lang = db_user["language"] if db_user else "ru"
        bot.answer_callback_query(call.id, "..." if lang == "en" else "Создаем счет...")
        _send_lava_invoice_for_chat(telegram_id, pkg["price_rub"], days, lang)
    except (RuntimeError, ValueError, KeyError) as exc:
        logger.error("Lava callback error: %s", exc)
        bot.send_message(call.message.chat.id, "Не удалось создать счёт. Попробуйте позже.")

@bot.callback_query_handler(func=lambda call: call.data.startswith("lang_"))
def handle_lang_callback(call):
    lang = call.data.split("_")[1]
    telegram_id = call.message.chat.id
    
    update_user_lang(telegram_id, lang)
    bot.answer_callback_query(call.id, MESSAGES[lang]["lang_success"])
    
    bot.send_message(telegram_id, MESSAGES[lang]["lang_success"], reply_markup=get_main_menu(lang))
    try:
        bot.delete_message(telegram_id, call.message.message_id)
    except Exception:
        pass

# Setup Bot commands and description branding programmatically
def setup_bot_branding():
    try:
        # Set commands
        commands = [
            types.BotCommand("start", "Запустить / Start"),
            types.BotCommand("profile", "Мой профиль / My Profile"),
            types.BotCommand("buy", "Купить подписку / Buy subscription"),
            types.BotCommand("instructions", "Инструкция / Setup Guide"),
            types.BotCommand("support", "Поддержка / Support")
        ]
        bot.set_my_commands(commands)
        
        # Set description (locale RU)
        bot.set_my_description(
            "🛡 **Mosaic vpn.** — быстрый и безопасный доступ к заблокированным ресурсам без ограничений скорости.\n\n"
            "🎁 **3 дня бесплатного тест-драйва** каждому новому пользователю!\n"
            "• Стоимость: **1 рубль в день**.\n"
            "• HWID лимит: до **5 устройств** на профиле.\n"
            "• Протокол **VLESS xHTTP** против блокировок.\n\n"
            "💬 Поддержка: @mosaicsup\n\n"
            "Нажмите /start, чтобы получить доступ!",
            language_code="ru"
        )
        # Set description (locale EN)
        bot.set_my_description(
            "🛡 **Mosaic vpn.** — fast and secure access to blocked resources without speed limits.\n\n"
            "🎁 **3-day FREE trial** for every new user!\n"
            "• Price: **1 ruble per day**.\n"
            "• HWID limit: up to **5 devices** per profile.\n"
            "• Core **VLESS xHTTP** protocol against censorship.\n\n"
            "💬 Support: @mosaicsup\n\n"
            "Type /start to begin!",
            language_code="en"
        )
        
        # Set short description (locale RU)
        bot.set_my_short_description(
            "🛡 Безопасный интернет за 1 рубль/день. 🎁 3 дня бесплатного теста на старте! Поддержка: @mosaicsup",
            language_code="ru"
        )
        # Set short description (locale EN)
        bot.set_my_short_description(
            "🛡 Secure internet for 1 ruble/day. 🎁 3-day free trial on start! Support: @mosaicsup",
            language_code="en"
        )
        logger.info("Bot commands and descriptions updated successfully.")
    except Exception as e:
        logger.error(f"Failed to setup bot commands/branding: {e}")

# Web API server serving Stats
class StatsRequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "https://sub.zxc1x1.ru")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_POST(self):
        # Protected POST payloads carry their token in JSON, not in a query
        # string; strip a stray query only for robust route matching.
        path = self.path.split("?", 1)[0].rstrip("/")
        if path in (LAVA_WEBHOOK_SITE_PATH, LAVA_WEBHOOK_BOT_PATH):
            return self._handle_lava_webhook("site" if path == LAVA_WEBHOOK_SITE_PATH else "bot")
        if path == "/api/billing/lava/create":
            return self._handle_lava_create()
        if path == "/api/checkout/create":
            return self._handle_lava_create(mobile_checkout=True)
        if path == "/api/account/freeze":
            return self._handle_account_freeze_change(True)
        if path == "/api/account/unfreeze":
            return self._handle_account_freeze_change(False)
        if path == "/api/subscription/link/rotate":
            return self._handle_subscription_link_rotate()
        if path == "/api/admin/balance-credit":
            return self._handle_admin_balance_credit()
        # T-19: the daemon runs behind NAT on the user's machine, so it is the
        # side that reaches out. The bot issues codes; this endpoint burns them.
        if path == "/api/link/redeem":
            return self._handle_link_redeem()
        # Web cabinet: exchange pairing code for a long-lived web session token
        if path == "/api/session":
            return self._handle_session_create()
        # Website-first app login. Browser and app exchange only a short-lived,
        # state-bound code; the web session is never embedded in a deep link.
        if path == "/api/app-auth/issue":
            return self._handle_app_auth_issue()
        if path == "/api/app-auth/exchange":
            return self._handle_app_auth_exchange()

        self.send_response(404)
        self._cors_headers()
        self.end_headers()

    def _handle_lava_create(self, mobile_checkout=False):
        payload = self._read_json_body()
        if not payload:
            self._send_json(400, {"error": "invalid body"})
            return
        token = str(payload.get("token") or "")
        session = get_web_session(token)
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return
        provider = str(payload.get("provider") or "lava").lower()
        if provider != "lava":
            self._send_json(400, {"error": "unsupported payment provider"})
            return
        try:
            amount = float(payload.get("amount_rub") if mobile_checkout else payload.get("amount"))
        except (TypeError, ValueError):
            self._send_json(400, {"error": "amount must be an integer number of RUB"})
            return
        if amount < 1 or amount > 100000 or amount != int(amount):
            self._send_json(400, {"error": "amount must be an integer from 1 to 100000 RUB"})
            return
        days = int(amount)
        try:
            invoice = create_lava_invoice("site", session["telegram_id"], amount, days, "MosaicVPN: пополнение веб-кабинета")
            save_lava_invoice(invoice["internal_id"], invoice["provider_id"], invoice["order_id"], session["telegram_id"], amount, days, "site")
        except (RuntimeError, ValueError) as exc:
            logger.error("Lava site invoice creation failed: %s", exc)
            self._send_json(502, {"error": "payment provider unavailable"})
            return
        response = {"payment_id": invoice["provider_id"], "order_id": invoice["order_id"], "amount": amount, "days": days, "status": "pending", "payment_url": invoice["payment_url"]}
        if mobile_checkout:
            response.update({
                "provider": "lava",
                "amount_rub": int(amount),
                "checkout_url": invoice["payment_url"],
                "message": "Оплата откроется в браузере. Доступ обновится после подтверждения платежа.",
            })
        self._send_json(200, response)

    def _handle_lava_webhook(self, store):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 65536:
                raise ValueError("invalid body")
            body = self.rfile.read(length)
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid body"})
            return
        signature = self.headers.get("Signature", "")
        if not signature:
            signature = self.headers.get("X-Signature", "")
        try:
            valid = verify_lava_webhook(store, body, signature)
        except RuntimeError:
            valid = False
        if not valid:
            self._send_json(401, {"error": "invalid webhook signature"})
            return
        status = str(_lava_value(payload, "status", "state", "paymentStatus", default="")).lower()
        if status not in {"paid", "success", "succeeded", "completed"}:
            self._send_json(200, {"status": "ignored", "payment_status": status or "unknown"})
            return
        order_id = _lava_value(payload, "orderId", "order_id", "order")
        provider_id = _lava_value(payload, "id", "invoiceId", "invoice_id", "paymentId", "payment_id")
        invoice = get_lava_invoice(order_id=order_id, provider_invoice_id=provider_id)
        if not invoice:
            self._send_json(404, {"error": "invoice not found"})
            return
        processed = process_lava_paid_invoice(invoice)
        self._send_json(200, {"status": "processed" if processed else "already_processed"})

    def _get_admin_session(self, token):
        """Validate a web session and require a server-configured administrator."""
        session = get_web_session(token)
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return None
        if not is_admin(session["telegram_id"]):
            self._send_json(403, {"error": "admin access required"})
            return None
        return session

    def _handle_admin_balance_credit(self):
        """Add paid-access days by account ID with auditability and idempotency."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 4096:
                raise ValueError("invalid body")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid body"})
            return

        session = self._get_admin_session(str(payload.get("token") or ""))
        if not session:
            return
        if payload.get("confirmed") is not True:
            self._send_json(400, {"error": "explicit confirmation required"})
            return

        request_id = str(payload.get("request_id") or "").strip()
        allowed_request_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        if not (16 <= len(request_id) <= 128) or any(ch not in allowed_request_chars for ch in request_id):
            self._send_json(400, {"error": "invalid request id"})
            return

        target_raw = str(payload.get("target_id") or "").strip()
        amount_raw = str(payload.get("amount") or "").strip()
        reason = str(payload.get("reason") or "").strip()
        if not target_raw.isdigit() or len(target_raw) > 19 or int(target_raw) <= 0:
            self._send_json(400, {"error": "target account ID must be a positive integer"})
            return
        if not amount_raw.isdigit() or int(amount_raw) < 1 or int(amount_raw) > ADMIN_CREDIT_MAX_RUB:
            self._send_json(400, {"error": f"amount must be an integer from 1 to {ADMIN_CREDIT_MAX_RUB} RUB"})
            return
        if not 3 <= len(reason) <= 240:
            self._send_json(400, {"error": "reason must contain 3 to 240 characters"})
            return

        target_telegram_id = int(target_raw)
        amount_rub = int(amount_raw)
        try:
            credit, claimed = claim_admin_balance_credit(
                request_id, session["telegram_id"], target_telegram_id, amount_rub, reason)
        except Exception:
            logger.exception("Admin credit ledger claim failed for request %s", request_id)
            self._send_json(503, {"error": "admin credit ledger is unavailable"})
            return

        if not claimed:
            same_request = (
                credit["admin_telegram_id"] == session["telegram_id"]
                and credit["target_telegram_id"] == target_telegram_id
                and credit["amount_rub"] == amount_rub
                and credit["reason"] == reason
            )
            if not same_request:
                self._send_json(409, {"error": "request id conflict"})
                return
            if credit["status"] == "succeeded":
                self._send_json(200, {
                    "status": "succeeded", "already_processed": True,
                    "request_id": request_id, "target_id": target_telegram_id,
                    "amount": amount_rub, "days": amount_rub,
                })
                return
            self._send_json(409, {
                "error": "request has already been recorded",
                "status": credit["status"],
                "request_id": request_id,
            })
            return

        api_username = f"tg_{target_telegram_id}"
        try:
            target_user = api_get_user(api_username)
            if not target_user:
                finish_admin_balance_credit(request_id, "failed", "account_not_found")
                self._send_json(404, {"error": "account ID not found"})
                return
            updated = api_extend_user(api_username, amount_rub)
            if not updated:
                finish_admin_balance_credit(request_id, "failed", "subscription_update_failed")
                self._send_json(502, {"error": "could not update subscription"})
                return
            short_uuid = updated.get("shortUuid") or ""
            finish_admin_balance_credit(request_id, "succeeded", resulting_short_uuid=short_uuid)
        except Exception:
            logger.exception("Admin credit execution failed for request %s", request_id)
            try:
                finish_admin_balance_credit(request_id, "failed", "internal_error")
            except Exception:
                logger.exception("Admin credit ledger completion failed for request %s", request_id)
            self._send_json(502, {"error": "could not update subscription"})
            return

        logger.info(
            "Admin %s credited %s RUB/days to account %s; request=%s",
            session["telegram_id"], amount_rub, target_telegram_id, request_id)
        self._send_json(200, {
            "status": "succeeded", "already_processed": False,
            "request_id": request_id, "target_id": target_telegram_id,
            "amount": amount_rub, "days": amount_rub,
        })

    def _account_payload(self, session, forced_status=None):
        """Build a single account representation for web and native cabinet clients."""
        telegram_id = session["telegram_id"]
        db_user = get_user(telegram_id)
        if not db_user:
            return None
        username = db_user.get("username") or session.get("username") or f"tg_{telegram_id}"
        remote = api_get_user(username)
        remote_status = str((remote or {}).get("status") or "ACTIVE").upper()
        status_map = {"DISABLED": "frozen", "EXPIRED": "insufficient_funds", "ACTIVE": "active"}
        status = forced_status or status_map.get(remote_status, "active")
        short_uuid = db_user.get("short_uuid") or (remote or {}).get("shortUuid") or ""
        expires_at = (remote or {}).get("expireAt")
        days_left = 0
        if expires_at:
            try:
                expiry = dateutil.parser.isoparse(expires_at)
                days_left = max(0, (expiry - datetime.datetime.now(datetime.timezone.utc)).days)
            except Exception:
                pass
        # Daily billing has an explicit Moscow-time estimate. It is labelled as
        # an estimate because provider-side billing may be paused or adjusted.
        next_charge_estimate_at = None
        if status == "active" and days_left > 0:
            now_moscow = datetime.datetime.now(ZoneInfo("Europe/Moscow"))
            next_charge_estimate_at = (now_moscow + datetime.timedelta(days=1)).replace(
                hour=0, minute=0, second=0, microsecond=0).isoformat()
        raw_devices = api_get_user_devices(username, remote) if remote else []
        devices = _cabinet_device_rows(raw_devices)
        traffic_used = int((remote or {}).get("usedTrafficBytes") or 0)
        traffic_limit = int((remote or {}).get("trafficLimitBytes") or 0)
        lifetime_traffic = int((remote or {}).get("lifetimeUsedTrafficBytes") or 0)
        device_limit = int((remote or {}).get("hwidDeviceLimit") or (remote or {}).get("hwidDevicesLimit") or 5)
        return {
            "account_id": str(telegram_id),
            "telegram_id": telegram_id,
            "username": username,
            "short_uuid": short_uuid,
            "sub_url": f"https://sub.zxc1x1.ru/{short_uuid}" if short_uuid else None,
            "subscription_url": f"https://sub.zxc1x1.ru/{short_uuid}" if short_uuid else None,
            "status": status,
            "tier": "trial" if not db_user.get("trial_used") else "standard",
            "balance": days_left,
            "balance_kopecks": days_left * 100,
            "currency": "RUB",
            "trial_ends_at": expires_at,
            "expires_at": expires_at,
            "days_left": days_left,
            "next_charge_estimate_at": next_charge_estimate_at,
            "traffic_used_bytes": traffic_used,
            "traffic_limit_bytes": traffic_limit,
            "lifetime_traffic_bytes": lifetime_traffic,
            "device_limit": max(0, device_limit),
            "devices": devices,
            "statistics": {
                "routes_available": 0,
                "devices_seen": len(devices),
                "provider_status": remote_status,
                "last_sync_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            },
            "billing": {"price_per_day_rub": 1, "timezone": "Europe/Moscow", "checkout_discount_percent": 0},
            "is_admin": is_admin(telegram_id),
        }

    def _authenticated_account_post(self):
        payload = self._read_json_body()
        if payload is None:
            self._send_json(400, {"error": "invalid body"})
            return None, None
        session = get_web_session(str(payload.get("token") or ""))
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return None, None
        return session, payload

    def _handle_account_freeze_change(self, frozen):
        session, _ = self._authenticated_account_post()
        if not session:
            return
        db_user = get_user(session["telegram_id"])
        username = (db_user or {}).get("username") or session["username"] or f"tg_{session['telegram_id']}"
        result = api_disable_user(username) if frozen else api_enable_user(username)
        if not result:
            self._send_json(502, {"error": "provider could not update account access"})
            return
        logger.info("Account %s was %s by its authenticated owner", session["telegram_id"], "frozen" if frozen else "unfrozen")
        account = self._account_payload(session, "frozen" if frozen else "active")
        self._send_json(200, {"account": account})

    def _handle_subscription_link_rotate(self):
        session, _ = self._authenticated_account_post()
        if not session:
            return
        db_user = get_user(session["telegram_id"])
        if not db_user:
            self._send_json(404, {"error": "user not found"})
            return
        username = db_user.get("username") or session["username"] or f"tg_{session['telegram_id']}"
        previous = db_user.get("short_uuid") or ""
        if not api_revoke_user_subscription(username):
            self._send_json(502, {"error": "provider could not rotate subscription link"})
            return
        refreshed = api_get_user(username) or {}
        short_uuid = str(refreshed.get("shortUuid") or "")
        if not short_uuid or short_uuid == previous:
            logger.error("Provider revoke did not return a new short UUID for user %s", session["telegram_id"])
            self._send_json(502, {"error": "provider did not confirm a new subscription link"})
            return
        save_user(session["telegram_id"], username, short_uuid,
                  db_user.get("language") or "ru", db_user.get("trial_used") or 0,
                  db_user.get("referrer_id"))
        logger.info("Subscription link rotated by authenticated owner for account %s", session["telegram_id"])
        self._send_json(200, {
            "short_uuid": short_uuid,
            "subscription_url": f"https://sub.zxc1x1.ru/{short_uuid}",
        })

    def _handle_subscription_base_profile(self, opaque_id):
        if not opaque_id or len(opaque_id) > 256:
            self._send_json(404, {"error": "subscription not found"})
            return
        profile = self.get_subscription_base_profile(opaque_id)
        if profile is None:
            self._send_json(404, {"error": "subscription not found"})
            return
        self._send_json(200, {"profile": profile})

    def _handle_provider_manifest(self, query):
        # Smart Groups are provider-owned route rows. Their concrete labels and
        # policies travel from the hosted authority; the app does not hard-code
        # a catalog or expose pool members. `subscription_id` is accepted as
        # context for future multi-account manifests but no secret is required
        # to read public route capability metadata.
        _ = (query.get("subscription_id") or [""])[0]
        policy = {
            "shard_size": 16,
            "max_parallel_probes": 4,
            "probe_ttl_seconds": 600,
            "max_failover_tries": 3,
            "latency_weight": 0.45,
            "loss_weight": 0.30,
            "stability_weight": 0.25,
            "speed_weight": 0.0,
            "speed_probe": {"enabled": False},
        }
        groups = [
            {
                "id": "rg-all", "title": "Минимальный пинг", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "lightning", "badge": "Авто", "description": "Выбор маршрута с минимальной задержкой на этом устройстве.",
                "client_policy": {**policy, "mode": "latency"},
            },
            {
                "id": "auto-stable", "title": "Оптимальный", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "shield", "badge": "Рекомендуется", "description": "Баланс стабильности и задержки с локальным failover.",
                "client_policy": {**policy, "mode": "stability", "stability_weight": 0.45, "latency_weight": 0.30},
            },
            {
                "id": "auto-speed", "title": "Максимальная скорость", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "speed", "badge": "Авто", "description": "Маршрут с клиентской проверкой производительности.",
                "client_policy": {**policy, "mode": "speed", "speed_weight": 0.45, "latency_weight": 0.25},
            },
            {
                "id": "auto-ru", "title": "Локальные сервисы (RU)", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "flag_ru", "badge": "Локальный", "description": "Автоматический маршрут для локального доступа.",
                "client_policy": {**policy, "mode": "latency"},
            },
            {
                "id": "auto-ca", "title": "Канада", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "flag_ca", "badge": "Авто", "description": "Канадский маршрут, если поддерживается вашим профилем.",
                "client_policy": {**policy, "mode": "latency"},
            },
            {
                "id": "auto-de", "title": "Германия", "route_type": "smart_group",
                "type": "urltest", "pool_id": "mosaicvpn", "category": "smart",
                "icon": "flag_de", "badge": "Авто", "description": "Немецкий маршрут, если поддерживается вашим профилем.",
                "client_policy": {**policy, "mode": "latency"},
            },
            {
                "id": "reserved-lte-compat", "title": "Свободный LTE", "route_type": "smart_group",
                "type": "urltest", "pool_id": "reserved-lte-compat", "category": "compatibility",
                "icon": "cellular", "badge": "Скоро", "description": "Категория зарезервирована до подключения авторизованного источника профилей.",
                "disabled": True, "disabled_reason": "Требуется подключение авторизованного источника профилей.",
                "client_policy": {**policy, "mode": "stability"},
            },
        ]
        self._send_json(200, {
            "provider_name": "MosaicVPN",
            "user_tier": "standard",
            "groups": groups,
        })

    def _handle_link_redeem(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 4096:
            self._send_json(400, {"error": "invalid body"})
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            code = payload.get("code", "")
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid body"})
            return

        if not code:
            self._send_json(400, {"error": "code required"})
            return

        try:
            result, reason = redeem_link_code(code)
        except Exception as exc:
            logging.error("redeem_link_code failed: %s", exc)
            self._send_json(500, {"error": "internal error"})
            return

        if result is None:
            status = {
                "not_found": 404,
                "expired": 410,
                "used": 409,
                "attempts": 429,
            }.get(reason, 400)
            self._send_json(status, {"error": reason})
            return

        # Android uses the same opaque direct subscription link as the desktop
        # client. A pairing code alone only identifies the account; it is not a
        # usable feed token. Return the user's existing short UUID and mint a
        # web session for cabinet endpoints in one atomic link response.
        db_user = get_user(result["telegram_id"])
        short_uuid = (db_user or {}).get("short_uuid") or ""
        if not short_uuid:
            self._send_json(404, {"error": "subscription profile not found"})
            return
        username = result.get("username", "")
        session_token, _ = create_web_session(result["telegram_id"], username)
        result["session_token"] = session_token
        result["direct_token"] = short_uuid
        result["subscription_url"] = f"https://sub.zxc1x1.ru/{short_uuid}"
        self._send_json(200, result)

    def _read_json_body(self, max_bytes=4096):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > max_bytes:
                raise ValueError("invalid body")
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            return None

    def _handle_app_auth_issue(self):
        payload = self._read_json_body()
        if not payload:
            self._send_json(400, {"error": "invalid body"})
            return
        token = str(payload.get("token") or "")
        state = str(payload.get("state") or "")
        purpose = str(payload.get("purpose") or "login")
        code = issue_app_auth_code(token, state, purpose)
        if not code:
            self._send_json(401, {"error": "invalid session or state"})
            return
        self._send_json(200, {
            "code": code,
            "purpose": purpose,
            "expires_in": APP_AUTH_CODE_TTL_SECONDS,
        })

    def _handle_app_auth_exchange(self):
        payload = self._read_json_body()
        if not payload:
            self._send_json(400, {"error": "invalid body"})
            return
        result, reason = redeem_app_auth_code(
            str(payload.get("code") or ""),
            str(payload.get("state") or ""),
        )
        if not result:
            status = {"not_found": 404, "expired": 410, "used": 409,
                      "state_mismatch": 400}.get(reason, 400)
            self._send_json(status, {"error": reason})
            return
        db_user = get_user(result["telegram_id"])
        short_uuid = (db_user or {}).get("short_uuid") or ""
        if not short_uuid:
            self._send_json(404, {"error": "subscription profile not found"})
            return
        session_token, _ = create_web_session(result["telegram_id"], result["username"])
        self._send_json(200, {
            "ok": True,
            "purpose": result.get("purpose", "login"),
            "telegram_id": result["telegram_id"],
            "username": result["username"],
            "session_token": session_token,
            "direct_token": short_uuid,
            "subscription_url": f"https://sub.zxc1x1.ru/{short_uuid}",
            "provider_id": "mosaicvpn",
            "provider_account_id": f"telegram:{result['telegram_id']}",
            "subscription_name": "MosaicVPN",
        })

    def _handle_session_create(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 4096:
            self._send_json(400, {"error": "invalid body"})
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            code = payload.get("code", "")
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid body"})
            return

        if not code:
            self._send_json(400, {"error": "code required"})
            return

        try:
            result, reason = redeem_link_code(code)
        except Exception as exc:
            logging.error("session create — redeem failed: %s", exc)
            self._send_json(500, {"error": "internal error"})
            return

        if result is None:
            status = {
                "not_found": 404,
                "expired": 410,
                "used": 409,
                "attempts": 429,
            }.get(reason, 400)
            self._send_json(status, {"error": reason})
            return

        telegram_id = result["telegram_id"]
        username = result.get("username", "")
        token, expires_at = create_web_session(telegram_id, username)
        self._send_json(200, {
            "token": token,
            "telegram_id": telegram_id,
            "username": username,
            "expires_at": expires_at,
        })

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        # /stats-api/stats/<shortUuid> — unchanged
        if path.startswith("/stats-api/stats/"):
            short_uuid = path.split("/")[-1]
            stats = self.get_user_statistics(short_uuid)
            if stats:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps(stats).encode("utf-8"))
                return
            self.send_response(404)
            self.end_headers()
            return

        # Capability-scoped base profile. The opaque subscription link is the
        # only lookup key, and the response is deliberately allow-listed: no
        # UUID, server address, direct token, payment data or control action.
        if path.startswith("/api/subscription/profile/"):
            opaque_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
            return self._handle_subscription_base_profile(opaque_id)

        # Provider route metadata for generic MosaicVPN clients. This endpoint
        # intentionally contains no share URIs or physical node pool; clients
        # receive the selected route's opaque feed separately.
        if path == "/api/manifest.json":
            return self._handle_provider_manifest(query)

        # Web cabinet: billing profile
        if path == "/api/billing/profile":
            return self._handle_billing_profile(query)

        # Web cabinet: payments history
        if path == "/api/billing/payments":
            return self._handle_billing_payments(query)
        if path == "/api/checkout/options":
            return self._handle_checkout_options(query)
        # Administrative journal, authorization is performed inside the handler.
        if path == "/api/admin/balance-credits":
            return self._handle_admin_balance_credit_history(query)

        self.send_response(404)
        self._cors_headers()
        self.end_headers()

    def _handle_billing_profile(self, query):
        token = query.get("token", [""])[0]
        session = get_web_session(token)
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return

        # The normalized fields below remain backward compatible with the
        # original profile while also satisfying the native unified cabinet.
        normalized = self._account_payload(session)
        if normalized:
            self._send_json(200, normalized)
            return

        telegram_id = session["telegram_id"]
        username = session["username"]
        db_user = get_user(telegram_id)
        if not db_user:
            self._send_json(404, {"error": "user not found"})
            return

        short_uuid = db_user.get("short_uuid") or ""
        user_data = api_get_user(username) if username else None

        profile = {
            "telegram_id": telegram_id,
            "username": username,
            "short_uuid": short_uuid,
            "tier": "trial" if not db_user.get("trial_used") else "standard",
            "sub_url": f"https://sub.zxc1x1.ru/{short_uuid}" if short_uuid else None,
            "expires_at": None,
            "days_left": 0,
            "balance": 0,
            "currency": "RUB",
            "devices": [],
            "is_admin": is_admin(telegram_id),
        }

        if user_data:
            expire_at_raw = user_data.get("expireAt")
            if expire_at_raw:
                profile["expires_at"] = expire_at_raw
                try:
                    expire_dt = dateutil.parser.isoparse(expire_at_raw)
                    now = datetime.datetime.now(datetime.timezone.utc)
                    profile["days_left"] = max(0, (expire_dt - now).days)
                except Exception:
                    pass
            traffic_used = user_data.get("usedTrafficBytes", 0) or 0
            traffic_limit = user_data.get("trafficLimitBytes", 0) or 0
            profile["traffic_used"] = traffic_used
            profile["traffic_limit"] = traffic_limit

        self._send_json(200, profile)

    def _handle_checkout_options(self, query):
        session = get_web_session(query.get("token", [""])[0])
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return
        self._send_json(200, {"providers": [{
            "id": "lava", "title": "СБП и банковские карты", "currency": "RUB",
            "available": True, "min_amount_rub": 10, "max_amount_rub": 100000,
        }]})

    def _handle_admin_balance_credit_history(self, query):
        session = self._get_admin_session(query.get("token", [""])[0])
        if not session:
            return
        try:
            limit = int(query.get("limit", ["50"])[0])
        except (TypeError, ValueError):
            limit = 50
        self._send_json(200, {"credits": get_admin_balance_credit_history(limit)})

    def _handle_billing_payments(self, query):
        token = query.get("token", [""])[0]
        session = get_web_session(token)
        if not session:
            self._send_json(401, {"error": "invalid or expired session"})
            return

        payments = get_payments_history(session["telegram_id"])
        self._send_json(200, {"payments": payments})

    def get_subscription_base_profile(self, short_uuid):
        """Return only metadata safe for the holder of a subscription URL.

        The subscription link is a bearer capability for receiving a feed, so
        this profile intentionally limits itself to access state and resource
        counters. Account identity, node inventory, UUIDs, payment history,
        devices and management operations remain session-authenticated.
        """
        try:
            pg_conn = psycopg2.connect(
                host="127.0.0.1", port=6767, user="postgres",
                password="postgres", database="postgres"
            )
            cursor = pg_conn.cursor()
            cursor.execute(
                "SELECT username, status, expire_at FROM users WHERE short_uuid = %s",
                (short_uuid,)
            )
            row = cursor.fetchone()
            if not row:
                cursor.close()
                pg_conn.close()
                return None
            username, raw_status, expire_at = row
            remote = api_get_user(username) or {}
            remote_status = str(remote.get("status") or raw_status or "ACTIVE").upper()
            status_map = {
                "ACTIVE": "active", "DISABLED": "frozen", "EXPIRED": "insufficient_funds"
            }
            if expire_at and expire_at.tzinfo is None:
                expire_at = expire_at.replace(tzinfo=datetime.timezone.utc)
            now = datetime.datetime.now(datetime.timezone.utc)
            expires_at = (remote.get("expireAt") or
                          (expire_at.isoformat() if expire_at else None))
            expiry = dateutil.parser.isoparse(expires_at) if expires_at else expire_at
            if expiry and expiry.tzinfo is None:
                expiry = expiry.replace(tzinfo=datetime.timezone.utc)
            days_left = max(0, (expiry - now).days) if expiry else 0
            cursor.close()
            pg_conn.close()
            return {
                "provider_name": "MosaicVPN",
                "status": status_map.get(remote_status, "unknown"),
                "tier": "standard",
                "expires_at": expires_at,
                "days_left": days_left,
                "traffic_used_bytes": int(remote.get("usedTrafficBytes") or 0),
                "traffic_limit_bytes": int(remote.get("trafficLimitBytes") or 0),
                "lifetime_traffic_bytes": int(remote.get("lifetimeUsedTrafficBytes") or 0),
                "device_limit": max(0, int(remote.get("hwidDeviceLimit") or remote.get("hwidDevicesLimit") or 0)),
                "last_sync_at": now.isoformat(),
            }
        except Exception as exc:
            logger.error("Base subscription profile lookup failed: %s", exc)
            return None

    def get_user_statistics(self, short_uuid):
        # Connect to Remnawave Postgres database
        try:
            pg_conn = psycopg2.connect(
                host="127.0.0.1",
                port=6767,
                user="postgres",
                password="postgres",
                database="postgres"
            )
            cursor = pg_conn.cursor()
            
            # Get user from PostgreSQL
            cursor.execute("SELECT t_id, uuid, username, status, expire_at, vless_uuid FROM users WHERE short_uuid = %s", (short_uuid,))
            user_row = cursor.fetchone()
            if not user_row:
                pg_conn.close()
                return None
                
            t_id, user_uuid, username, status, expire_at, vless_uuid = user_row
            
            # Get traffic usage
            cursor.execute("SELECT used_traffic_bytes, lifetime_used_traffic_bytes FROM user_traffic WHERE t_id = %s", (t_id,))
            traffic_row = cursor.fetchone()
            used_bytes = traffic_row[0] if traffic_row else 0
            life_bytes = traffic_row[1] if traffic_row else 0
            
            # Get favorite connection server
            cursor.execute("""
                SELECT n.name FROM nodes_user_usage_history h 
                JOIN nodes n ON h.node_id = n.id 
                WHERE h.user_id = %s 
                ORDER BY h.total_bytes DESC LIMIT 1
            """, (t_id,))
            fav_row = cursor.fetchone()
            fav_server = fav_row[0] if fav_row else "Напрямую"
            
            # Get connection clients / user agents
            cursor.execute("""
                SELECT user_agent FROM user_subscription_request_history 
                WHERE user_uuid = %s AND user_agent IS NOT NULL 
                GROUP BY user_agent 
                ORDER BY MAX(request_at) DESC LIMIT 4
            """, (user_uuid,))
            ua_rows = cursor.fetchall()
            
            clients = []
            for (ua,) in ua_rows:
                ua_lower = ua.lower()
                if "shadowrocket" in ua_lower:
                    clients.append("Shadowrocket (iOS)")
                elif "mosaic" in ua_lower:
                    clients.append("MosaicVPN")
                elif "hiddify" in ua_lower:
                    clients.append("Hiddify Next")
                elif "exclave" in ua_lower or "nekobox" in ua_lower:
                    clients.append("Exclave")
                elif "chrome" in ua_lower or "safari" in ua_lower or "mozilla" in ua_lower:
                    clients.append("Web Browser")
                else:
                    clients.append(ua.split("/")[0])
            
            # Deduplicate clients
            clients = list(dict.fromkeys(clients))
            if not clients:
                clients = ["MosaicVPN"]
                
            # Get active hosts
            cursor.execute("""
                SELECT remark, uuid, address, port, security_layer, sni, path, xhttp_extra_params 
                FROM hosts WHERE is_disabled = false ORDER BY view_position
            """)
            host_rows = cursor.fetchall()
            hosts = []
            for h in host_rows:
                extra = h[7]
                if extra and isinstance(extra, str):
                    try:
                        extra = json.loads(extra)
                    except Exception:
                        pass
                hosts.append({
                    "remark": h[0],
                    "uuid": h[1],
                    "address": h[2],
                    "port": h[3],
                    "security_layer": h[4],
                    "sni": h[5],
                    "path": h[6],
                    "xhttp_extra_params": extra
                })
                
            cursor.close()
            pg_conn.close()
            
            # Calculate remaining days
            now = datetime.datetime.now(datetime.timezone.utc)
            if expire_at.tzinfo is None:
                expire_at = expire_at.replace(tzinfo=datetime.timezone.utc)
                
            days_left = (expire_at - now).days
            if days_left < 0: days_left = 0
            
            # Generate estimated ping/speed based on server
            avg_ping = 25 if "CDN" in fav_server else (35 if "EU" in fav_server or "пинг" in fav_server.lower() else 45)
            avg_speed = 185 if "скорость" in fav_server.lower() else (120 if "CDN" in fav_server else 150)
            
            return {
                "balance": days_left, # 1 ruble per day
                "days_left": days_left,
                "used_traffic_gb": used_bytes / (1024**3),
                "lifetime_traffic_gb": life_bytes / (1024**3),
                "favorite_server": fav_server,
                "clients": clients[:3],
                "avg_speed": avg_speed,
                "avg_ping": avg_ping
            }
            
        except Exception as e:
            logger.error(f"Error querying Postgres for stats: {e}")
            
        # Fallback if DB query fails
        return {
            "balance": 0,
            "days_left": 0,
            "used_traffic_gb": 0.0,
            "lifetime_traffic_gb": 0.0,
            "favorite_server": "Напрямую",
            "clients": ["MosaicVPN"],
            "avg_speed": 150,
            "avg_ping": 35,
            "vless_uuid": "",
            "hosts": []
        }

def get_domain_from_secret(secret):
    try:
        hex_secret = ""
        if all(c in "0123456789abcdefABCDEF" for c in secret):
            hex_secret = secret.lower()
        else:
            try:
                padded = secret + "=" * ((4 - len(secret) % 4) % 4)
                hex_secret = base64.b64decode(padded).hex().lower()
            except Exception:
                pass
                
        if hex_secret.startswith("ee") and len(hex_secret) > 34:
            domain_hex = hex_secret[34:]
            domain_bytes = bytes.fromhex(domain_hex)
            domain = domain_bytes.decode('utf-8', errors='ignore')
            domain = "".join(c for c in domain if c.isprintable()).strip()
            if domain:
                return domain
    except Exception:
        pass
    return None

@bot.message_handler(commands=["proxies"])
@bot.message_handler(func=lambda m: m.text in [MESSAGES["ru"]["menu_proxies"], MESSAGES["en"]["menu_proxies"]])
def show_proxies_menu(message):
    telegram_id = message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    t = MESSAGES[lang]
    
    markup = types.InlineKeyboardMarkup(row_width=2)
    markup.add(
        types.InlineKeyboardButton("🇷🇺 RU MTProto", callback_data="proxy_ru"),
        types.InlineKeyboardButton("🇪🇺 EU MTProto", callback_data="proxy_eu"),
        types.InlineKeyboardButton("🌍 All MTProto", callback_data="proxy_all"),
        types.InlineKeyboardButton("🔌 SOCKS5", callback_data="proxy_socks5")
    )
    bot.send_message(telegram_id, t["proxies_welcome"], parse_mode="Markdown", reply_markup=markup)

def check_proxy_alive(server, port, timeout=8, proxy_type="mtproto", secret=None):
    """
    Проверяет прокси, пытаясь реально подключиться к Telegram через него.
    proxy_type: 'mtproto' или 'socks5'
    Для MTProto: подключаемся через SOCKS5 к серверу и делаем handshake к Telegram DC.
    Для SOCKS5: подключаемся через SOCKS5 к api.telegram.org:443.
    Если подключение и SOCKS5 handshake прошли — прокси живой для Telegram.
    """
    import socket
    try:
        s = socks.socksocket()
        s.settimeout(timeout)
        if proxy_type == "socks5":
            s.set_proxy(socks.SOCKS5, server, int(port))
            # Пытаемся подключиться к Telegram API через этот SOCKS5
            s.connect(("api.telegram.org", 443))
        else:
            # MTProto прокси — это тоже SOCKS5-подобный протокол (dd prefix в secret)
            # Но стандартный SOCKS5 клиент не понимает MTProto secret.
            # Поэтому для MTProto делаем проверку: подключаемся к серверу,
            # отправляем SOCKS5 handshake до Telegram DC.
            # Полноценная проверка MTProto требует реализации протокола.
            # Упрощённая проверка: TCP-доступность + попытка SOCKS5 handshake.
            s.set_proxy(socks.SOCKS5, server, int(port))
            s.connect(("api.telegram.org", 443))
        s.close()
        return True
    except Exception:
        try:
            socket.create_connection((server, int(port)), timeout=timeout/2).close()
            return True
        except Exception:
            return False


def check_proxy_from_ru(server, port):
    """
    Проверяет доступность TCP-порта прокси-сервера из РФ с помощью check-host.net.
    Возвращает:
      True — если доступен из РФ.
      False — если заблокирован/недоступен из РФ.
      None — в случае ошибки API или лимитов (неизвестно).
    """
    import random
    try:
        # Небольшая задержка перед запросом, чтобы снизить риск превышения лимитов API при параллельной проверке
        time.sleep(random.uniform(0.1, 0.4))
        
        url = f"https://check-host.net/check-tcp?host={server}:{port}&node=ru1.node.check-host.net&node=ru2.node.check-host.net&node=ru3.node.check-host.net"
        headers = {"Accept": "application/json"}
        res = requests.get(url, headers=headers, timeout=6)
        if res.status_code != 200:
            logger.warning(f"check-host init failed for {server}:{port}: HTTP {res.status_code}")
            return None
        data = res.json()
        request_id = data.get("request_id")
        if not request_id:
            logger.warning(f"No request_id in check-host response for {server}:{port}")
            return None
        
        # Дадим нодам check-host немного времени для выполнения tcp connect (обычно 2 сек)
        time.sleep(2.2)
        
        # Делаем до 4 попыток получить результаты
        for attempt_idx in range(4):
            result_res = requests.get(f"https://check-host.net/check-result/{request_id}", headers=headers, timeout=5)
            if result_res.status_code == 200:
                result_data = result_res.json()
                if result_data:
                    success_count = 0
                    total_ru_nodes = 0
                    for node in ["ru1.node.check-host.net", "ru2.node.check-host.net", "ru3.node.check-host.net"]:
                        if node in result_data:
                            node_results = result_data[node]
                            if node_results is not None:
                                total_ru_nodes += 1
                                for attempt in node_results:
                                    # Если в попытке коннекта нет error, считаем успешной
                                    if isinstance(attempt, dict) and "error" not in attempt:
                                        success_count += 1
                                        break
                    if total_ru_nodes > 0:
                        is_alive = (success_count >= 1)
                        logger.info(f"RU check for {server}:{port}: {success_count}/{total_ru_nodes} nodes successful. Alive: {is_alive}")
                        return is_alive
            time.sleep(1.2)
    except Exception as e:
        logger.error(f"Error in check_proxy_from_ru for {server}:{port}: {e}")
    return None


def validate_proxies(proxies_list, max_workers=10, timeout=8):
    """Validate proxy links by attempting real SOCKS5 connection to Telegram through each,
    and then prioritizing endpoints that are accessible from Russia (DPI-survival).
    Returns (alive_list, dead_list)."""
    future_to_link = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        for link in proxies_list:
            parsed = urllib.parse.urlparse(link)
            query = urllib.parse.parse_qs(parsed.query)
            server = query.get("server", [""])[0]
            port = query.get("port", [""])[0]
            secret = query.get("secret", [""])[0]
            if server and port:
                ptype = "socks5" if "socks5" in link else "mtproto"
                future = executor.submit(check_proxy_alive, server, port, timeout, ptype, secret)
                future_to_link[future] = link
        alive = []
        dead = []
        results = {}
        for future in concurrent.futures.as_completed(future_to_link):
            link = future_to_link[future]
            try:
                is_alive = future.result()
            except Exception:
                is_alive = False
            results[link] = is_alive
        
        vps_alive = []
        for link in proxies_list:
            if link in results:
                if results[link]:
                    vps_alive.append(link)
                else:
                    dead.append(link)

    # Дополнительно проверяем из РФ прокси, прошедшие TCP-проверку (vps_alive)
    # Ограничиваемся первыми 12 кандидатами для проверки из РФ, чтобы не перегружать API
    candidates_for_ru = vps_alive[:12]
    confirmed_ru = []
    unknown_ru = []
    dead_ru = []
    
    if candidates_for_ru:
        logger.info(f"Starting RU verification for {len(candidates_for_ru)} VPS-alive proxies...")
        ru_future_to_link = {}
        # Запускаем проверку из РФ в 4 потока, чтобы не спамить
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            for link in candidates_for_ru:
                parsed = urllib.parse.urlparse(link)
                query = urllib.parse.parse_qs(parsed.query)
                server = query.get("server", [""])[0]
                port = query.get("port", [""])[0]
                if server and port:
                    future = executor.submit(check_proxy_from_ru, server, port)
                    ru_future_to_link[future] = link
            
            for future in concurrent.futures.as_completed(ru_future_to_link):
                link = ru_future_to_link[future]
                try:
                    ru_res = future.result()
                except Exception as e:
                    logger.error(f"Error retrieving RU verify result: {e}")
                    ru_res = None
                
                if ru_res is True:
                    confirmed_ru.append(link)
                elif ru_res is False:
                    dead_ru.append(link)
                else:
                    unknown_ru.append(link)
        logger.info(f"RU verify results: confirmed_ru={len(confirmed_ru)}, unknown_ru={len(unknown_ru)}, dead_ru={len(dead_ru)}")

    vps_alive_remains = vps_alive[12:]
    alive = confirmed_ru + unknown_ru + vps_alive_remains
    dead = list(set(dead + dead_ru))
    return alive, dead


@bot.callback_query_handler(func=lambda call: call.data.startswith("proxy_"))
def handle_proxy_callback(call):
    telegram_id = call.message.chat.id
    db_user = get_user(telegram_id)
    lang = db_user["language"] if db_user else "ru"
    t = MESSAGES[lang]
    
    proxy_type = call.data.split("_")[1]
    
    bot.answer_callback_query(call.id, t["proxies_loading"])
    
    urls_primary = {
        "ru": "https://raw.githubusercontent.com/kort0881/telegram-proxy-collector/main/proxy_ru.txt",
        "eu": "https://raw.githubusercontent.com/kort0881/telegram-proxy-collector/main/proxy_eu.txt",
        "all": "https://raw.githubusercontent.com/kort0881/telegram-proxy-collector/main/proxy_all.txt",
        "socks5": "https://raw.githubusercontent.com/kort0881/telegram-proxy-collector/main/socks5.txt"
    }

    urls_fallback = {
        "ru": "https://raw.githubusercontent.com/Argh94/Proxy-List/main/MTProto.txt",
        "eu": "https://raw.githubusercontent.com/Argh94/Proxy-List/main/MTProto.txt",
        "all": "https://raw.githubusercontent.com/Argh94/Proxy-List/main/MTProto.txt",
        "socks5": "https://raw.githubusercontent.com/Argh94/Proxy-List/main/SOCKS5.txt"
    }
    
    proxies = []
    if proxy_type in ["ru", "eu", "all"]:
        logger.info(f"Fetching MTProto proxies from TG channel ProxyMTProto...")
        try:
            import re, html
            res_tg = requests.get("https://t.me/s/ProxyMTProto", timeout=8)
            if res_tg.status_code == 200:
                tg_proxies = re.findall(r'tg://proxy\?[^\"]*', res_tg.text)
                for p in tg_proxies:
                    p_dec = html.unescape(p)
                    if p_dec not in proxies:
                        proxies.append(p_dec)
                proxies.reverse()
                logger.info(f"Successfully scraped {len(proxies)} MTProto proxies from TG feed")
        except Exception as e:
            logger.error(f"Failed to scrape MTProto proxies from TG channel: {e}")

    try:
        if not proxies:
            url = urls_primary.get(proxy_type)
            if not url:
                bot.send_message(telegram_id, t["proxies_error"])
                return
                
            res = None
            try:
                res = requests.get(url, timeout=10)
            except Exception as e:
                logger.warning(f"Failed to fetch primary proxy list from {url}: {e}")

            if not res or res.status_code != 200:
                fallback_url = urls_fallback.get(proxy_type)
                logger.info(f"Trying fallback proxy list from {fallback_url}...")
                try:
                    res = requests.get(fallback_url, timeout=10)
                except Exception as e:
                    logger.error(f"Failed to fetch fallback proxy list from {fallback_url}: {e}")

            if not res or res.status_code != 200:
                bot.send_message(telegram_id, t["proxies_error"])
                return
                
            lines = res.text.splitlines()
            for line in lines:
                line = line.strip()
                if line.startswith("tg://"):
                    proxies.append(line)
                    
        if not proxies:
            bot.send_message(telegram_id, t["proxies_error"])
            return
            return
            
        # TCP-проверка с VPS: фильтруем мёртвые серверы
        # ВАЖНО: TCP alive не гарантирует работу из РФ (DPI может блокировать MTProto-трафик),
        # но отбрасывает полностью выключенные серверы
        candidates = proxies[:30]
        alive_proxies, dead_proxies = validate_proxies(candidates, max_workers=10, timeout=5)
        top_proxies = alive_proxies[:9]
        
        if not top_proxies:
            top_proxies = proxies[:9]
            logger.warning("All %d proxies dead, fallback to unvalidated" % len(candidates))
        
        logger.info("Proxy check: %d alive / %d dead out of %d checked" % (len(alive_proxies), len(dead_proxies), len(candidates)))
        
        text = t["proxies_list_title"] + "\n\n"
        markup = types.InlineKeyboardMarkup(row_width=1)
        
        for idx, link in enumerate(top_proxies, 1):
            parsed = urllib.parse.urlparse(link)
            query = urllib.parse.parse_qs(parsed.query)
            
            server = query.get("server", [""])[0]
            port = query.get("port", [""])[0]
            secret = query.get("secret", [""])[0]
            
            mask_info = ""
            if secret:
                domain = get_domain_from_secret(secret)
                if domain:
                    mask_info = f" (Mask: {domain})"
                    
            if proxy_type == "socks5":
                text += f"⚡ **Proxy #{idx}**\n`{server}:{port}`\n\n"
                btn_text = f"Connect SOCKS5 #{idx}"
            else:
                text += f"⚡ **Proxy #{idx}**{mask_info}\n`{server}:{port}`\n\n"
                btn_text = f"Connect MTProto #{idx}"
                
            markup.add(types.InlineKeyboardButton(btn_text, url=link))
            
        bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)
        
    except Exception as e:
        logger.error(f"Error fetching/parsing proxies: {e}")
        bot.send_message(telegram_id, t["proxies_error"])


def _migrate_blocked_columns():
    """Add users.blocked / users.blocked_at when missing (idempotent)."""
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        cur.execute("PRAGMA table_info(users)")
        cols = {r[1] for r in cur.fetchall()}
        if "blocked" not in cols:
            cur.execute("ALTER TABLE users ADD COLUMN blocked INTEGER DEFAULT 0")
        if "blocked_at" not in cols:
            cur.execute("ALTER TABLE users ADD COLUMN blocked_at TEXT")
        conn.commit()
        conn.close()
    except Exception as e:
        logger.error(f"blocked-column migration failed: {e}")


def mark_user_blocked(telegram_id):
    """Flag a user who can no longer receive messages, so the funnel skips them."""
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        now_str = datetime.datetime.now(datetime.timezone.utc).isoformat()
        cur.execute("UPDATE users SET blocked = 1, blocked_at = ? WHERE telegram_id = ?",
                    (now_str, telegram_id))
        conn.commit()
        conn.close()
        logger.info(f"user {telegram_id} marked blocked; funnel will skip them")
    except Exception as e:
        logger.error(f"failed to mark user {telegram_id} blocked: {e}")


def clear_blocked_flag(telegram_id):
    """A user who talks to the bot again is reachable; clear the flag."""
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        cur.execute("SELECT blocked FROM users WHERE telegram_id = ?", (telegram_id,))
        row = cur.fetchone()
        if row and row[0]:
            cur.execute("UPDATE users SET blocked = 0, blocked_at = NULL WHERE telegram_id = ?",
                        (telegram_id,))
            conn.commit()
            logger.info(f"user {telegram_id} is reachable again; blocked flag cleared")
        conn.close()
    except Exception as e:
        logger.error(f"failed to clear blocked flag for {telegram_id}: {e}")


def _is_unreachable_error(err):
    """True when Telegram says the user can never receive our messages."""
    msg = str(err).lower()
    return ("blocked by the user" in msg
            or "user is deactivated" in msg
            or "chat not found" in msg
            or "bot was kicked" in msg
            or "peer_id_invalid" in msg)

def send_funnel_notification(telegram_id, notification_type, text, markup=None):
    try:
        bot.send_message(telegram_id, text, parse_mode="Markdown", reply_markup=markup)
        
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        now_str = datetime.datetime.now(datetime.timezone.utc).isoformat()
        cursor.execute(
            "INSERT INTO notification_history (telegram_id, notification_type, sent_at) VALUES (?, ?, ?)",
            (telegram_id, notification_type, now_str)
        )
        conn.commit()
        conn.close()
        logger.info(f"Sent funnel notification '{notification_type}' to user {telegram_id}")
    except Exception as e:
        if _is_unreachable_error(e):
            # The user blocked the bot or the chat is gone. Recording the
            # attempt is pointless -- flag them so the funnel stops
            # re-selecting this user on every single pass.
            mark_user_blocked(telegram_id)
            logger.warning(f"skipping funnel '{notification_type}' for {telegram_id}: unreachable ({e})")
        else:
            logger.error(f"Failed to send funnel notification '{notification_type}' to {telegram_id}: {e}")

def run_notifications_check():
    now = datetime.datetime.now(datetime.timezone.utc)
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    cursor.execute("SELECT telegram_id, username, created_at, language, trial_used, referrer_id FROM users WHERE COALESCE(blocked, 0) = 0")
    db_users = cursor.fetchall()
    
    for telegram_id, username, db_created_at_str, lang, trial_used, referrer_id in db_users:
        try:
            cursor.execute("SELECT notification_type FROM notification_history WHERE telegram_id = ?", (telegram_id,))
            sent_notifications = {row[0] for row in cursor.fetchall()}
            
            user_data = api_get_user(username)
            if not user_data:
                continue
            
            created_at_str = user_data.get("createdAt") or db_created_at_str
            if not created_at_str:
                continue
            
            created_dt = dateutil.parser.isoparse(created_at_str)
            time_since_creation = now - created_dt
            
            user_traffic = user_data.get("userTraffic", {}) or {}
            first_connected_raw = user_traffic.get("firstConnectedAt")
            lifetime_traffic = user_traffic.get("lifetimeUsedTrafficBytes") or 0
            
            has_traffic = (first_connected_raw is not None) or (lifetime_traffic > 0)
            
            short_uuid = user_data.get("shortUuid")
            sub_url = f"https://sub.zxc1x1.ru/{short_uuid}" if short_uuid else ""
            
            # --- MOCK REMNAWAVE NETWORK TRANSIT ---
            # As reality servers might be down or not responding correctly,
            # we make sure that if a user has signed up but has not connected yet,
            # we check the state machine normally.
            
            if has_traffic:
                if first_connected_raw:
                    first_connected_dt = dateutil.parser.isoparse(first_connected_raw)
                else:
                    first_connected_dt = created_dt
                
                time_since_traffic = now - first_connected_dt
                
                # traffic_6h: 6 hours after traffic start
                if time_since_traffic >= datetime.timedelta(hours=6) and "traffic_6h" not in sent_notifications:
                    text = (
                        "Вы подключились, отлично! ✅ VPN работает.\n\n"
                        "Когда пробный период закончится — мы напишем и напомним вам о продлении."
                        if lang == "ru" else
                        "You connected successfully! ✅ VPN works.\n\n"
                        "We will notify you before your trial expires."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("💎 Тарифы" if lang == "ru" else "💎 Tariffs", callback_data="show_tariffs"))
                    markup.row(types.InlineKeyboardButton("🎁 Пригласить друга" if lang == "ru" else "🎁 Invite a Friend", callback_data="ref_link"))
                    send_funnel_notification(telegram_id, "traffic_6h", text, markup)

                # #9: 3-day pre-expire reminder with 1-tap renew
                elif time_since_traffic >= datetime.timedelta(hours=3*24) and "rating_request" not in sent_notifications and "pre_expire_3d_renew" not in sent_notifications:
                    # Check actual expiry — if subscription is 3 days from ending
                    expire_at_raw = user_data.get("expireAt")
                    if expire_at_raw:
                        try:
                            expire_dt = dateutil.parser.isoparse(expire_at_raw)
                            days_until_expire = (expire_dt - now).days
                            if 2 <= days_until_expire <= 4:
                                text = (
                                    f"⏰ Ваша подписка заканчивается через {days_until_expire} дн.\n\n"
                                    f"Продлите сейчас в один клик — настройки сохранятся, VPN не прервётся."
                                    if lang == "ru" else
                                    f"⏰ Your subscription expires in {days_until_expire} days.\n\n"
                                    f"Renew with one tap — settings stay, VPN won't interrupt."
                                )
                                markup = types.InlineKeyboardMarkup(row_width=1)
                                markup.add(types.InlineKeyboardButton("🔁 Продлить 30 дней" if lang == "ru" else "🔁 Renew 30 days", callback_data="renew_30"))
                                markup.add(types.InlineKeyboardButton("🔁 Продлить 90 дней" if lang == "ru" else "🔁 Renew 90 days", callback_data="renew_90"))
                                send_funnel_notification(telegram_id, "pre_expire_3d_renew", text, markup)
                        except Exception:
                            pass

                # #12: Rating request — 3 days after first connection
                elif time_since_traffic >= datetime.timedelta(hours=3*24) and "rating_request" not in sent_notifications and "pre_expire_3d_renew" in sent_notifications:
                    if not db_user.get("rating_given", 0):
                        text = (
                            "⭐ Как вам Mosaic VPN?\n\n"
                            "Оцените нас — это поможет стать лучше!"
                            if lang == "ru" else
                            "⭐ How do you like Mosaic VPN?\n\n"
                            "Rate us — it helps us improve!"
                        )
                        markup = types.InlineKeyboardMarkup(row_width=5)
                        markup.row(*[types.InlineKeyboardButton(f"{'⭐'*n}", callback_data=f"rate_{n}") for n in range(1,6)])
                        send_funnel_notification(telegram_id, "rating_request", text, markup)
                
                # traffic_12h_dis: 12 hours after traffic start (50% discount)
                elif time_since_traffic >= datetime.timedelta(hours=12) and "traffic_12h_dis" not in sent_notifications:
                    text = (
                        "У вас всё работает отлично! ✅\n\n"
                        "Специально для новых пользователей — **скидка 50%** на первую подписку! Предложение действует ровно 24 часа."
                        if lang == "ru" else
                        "Everything works great for you! ✅\n\n"
                        "Special offer for new users — **50% discount** on your first subscription! Valid for 24 hours only."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("🏷 Оформить со скидкой 50%" if lang == "ru" else "🏷 Buy with 50% OFF", callback_data="buy_discount"))
                    send_funnel_notification(telegram_id, "traffic_12h_dis", text, markup)
                
                # traffic_12h_dis_end: 12 hours after discount (24 hours after traffic start)
                elif time_since_traffic >= datetime.timedelta(hours=24) and "traffic_12h_dis" in sent_notifications and "traffic_12h_dis_end" not in sent_notifications:
                    text = (
                        "До конца действия скидки 50% осталось совсем немного ⏰\n\n"
                        "После этого подписка будет доступна по обычной цене."
                        if lang == "ru" else
                        "Only a short time left for your 50% discount! ⏰\n\n"
                        "After it expires, subscription plans will be at standard rates."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("🏷 Оформить со скидкой 50%" if lang == "ru" else "🏷 Buy with 50% OFF", callback_data="buy_discount"))
                    send_funnel_notification(telegram_id, "traffic_12h_dis_end", text, markup)
                
                # trial_expire_tomorrow: 24h before trial ends (48h after setup)
                elif time_since_creation >= datetime.timedelta(hours=48) and "trial_expire_tomorrow" not in sent_notifications:
                    text = (
                        "Ваш пробный период заканчивается завтра ⏳\n\n"
                        "Чтобы не потерять доступ — оформите подписку. Настройки сохранятся автоматически, ничего переподключать не нужно."
                        if lang == "ru" else
                        "Your trial period ends tomorrow ⏳\n\n"
                        "To prevent interruption — purchase a subscription now. All configurations remain active."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("💎 Выбрать тариф" if lang == "ru" else "💎 Tariffs", callback_data="show_tariffs"))
                    send_funnel_notification(telegram_id, "trial_expire_tomorrow", text, markup)
                
                # trial_expired: 72h after signup
                elif time_since_creation >= datetime.timedelta(hours=72) and "trial_expired" not in sent_notifications:
                    expire_at_raw = user_data.get("expireAt")
                    is_expired = False
                    if expire_at_raw:
                        expire_dt = dateutil.parser.isoparse(expire_at_raw)
                        is_expired = (expire_dt < now) or (user_data.get("status") == "EXPIRED")
                    
                    if is_expired:
                        text = (
                            "⏰ Пробный период закончился\n\n"
                            "Оформите подписку — VPN снова заработает мгновенно, без повторной настройки."
                            if lang == "ru" else
                            "⏰ Your trial period has ended\n\n"
                            "Choose a subscription plan to resume connection. No re-configuration is needed."
                        )
                        markup = types.InlineKeyboardMarkup()
                        markup.row(types.InlineKeyboardButton("💎 Выбрать тариф" if lang == "ru" else "💎 Tariffs", callback_data="show_tariffs"))
                        send_funnel_notification(telegram_id, "trial_expired", text, markup)
            
            else:
                # --- NO TRAFFIC FUNNEL ---
                # no_traffic_1h: 1 hour after signup
                if time_since_creation >= datetime.timedelta(hours=1) and "no_traffic_1h" not in sent_notifications:
                    text = (
                        "🆘 Не получилось подключиться?\n\n"
                        "Напишите нам — поможем настроить за пару минут."
                        if lang == "ru" else
                        "🆘 Having trouble connecting?\n\n"
                        "Drop us a line — we'll help get it sorted in 2 minutes."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("🆘 Помочь подключить" if lang == "ru" else "🆘 Get Help / Support", url="https://t.me/mosaicsup"))
                    send_funnel_notification(telegram_id, "no_traffic_1h", text, markup)
                
                # no_traffic_24h: 24 hours after signup
                elif time_since_creation >= datetime.timedelta(hours=24) and "no_traffic_24h" not in sent_notifications:
                    text = (
                        "Ваш бесплатный VPN всё ещё ждёт вас ⏳\n\n"
                        "Подключение занимает ровно 2 минуты — перейдите по ссылке ниже, там всё просто."
                        if lang == "ru" else
                        "Your free VPN is waiting for you ⏳\n\n"
                        "It takes just 2 minutes to set up — click the subscription link below to begin."
                    )
                    markup = types.InlineKeyboardMarkup()
                    if sub_url:
                        markup.row(types.InlineKeyboardButton("🗺 Открыть веб-карту" if lang == "ru" else "🗺 Web Map", url=sub_url))
                    markup.row(types.InlineKeyboardButton("🆘 Помочь подключить" if lang == "ru" else "🆘 Help Connection", url="https://t.me/mosaicsup"))
                    send_funnel_notification(telegram_id, "no_traffic_24h", text, markup)
                
                # no_traffic_48h: 48 hours after signup
                elif time_since_creation >= datetime.timedelta(hours=48) and "no_traffic_48h" not in sent_notifications:
                    text = (
                        "⏰ Ваш пробный период заканчивается завтра\n\n"
                        "После этого доступ будет закрыт. Подключитесь сейчас — это займет пару минут!"
                        if lang == "ru" else
                        "⏰ Your free trial expires tomorrow\n\n"
                        "After that, access will be revoked. Set up your client now — it takes only 2 minutes!"
                    )
                    markup = types.InlineKeyboardMarkup()
                    if sub_url:
                        markup.row(types.InlineKeyboardButton("🗺 Открыть веб-карту" if lang == "ru" else "🗺 Web Map", url=sub_url))
                    markup.row(types.InlineKeyboardButton("🆘 Помочь подключить" if lang == "ru" else "🆘 Help Connection", url="https://t.me/mosaicsup"))
                    send_funnel_notification(telegram_id, "no_traffic_48h", text, markup)
                
                # no_traffic_expired: 72 hours after signup (expired, no traffic)
                elif time_since_creation >= datetime.timedelta(hours=72) and "no_traffic_expired" not in sent_notifications:
                    text = (
                        "⏰ Ваш пробный период закончился\n\n"
                        "Но мы готовы дать вам второй шанс — напишите нам, и мы поможем подключить VPN и продлим ваш пробный доступ!"
                        if lang == "ru" else
                        "⏰ Your trial period has ended\n\n"
                        "We are ready to give you a second chance! Message us, we'll help you configure it and extend your trial."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("🔑 Получить доступ" if lang == "ru" else "🆘 Message Support", url="https://t.me/mosaicsup"))
                    send_funnel_notification(telegram_id, "no_traffic_expired", text, markup)
                
                # no_traffic_7d: 7 days after expiry (10 days after signup)
                elif time_since_creation >= datetime.timedelta(days=10) and "no_traffic_7d" not in sent_notifications:
                    text = (
                        "Всё ещё ищете качественный VPN?\n\n"
                        "Мы на связи! Напишите нам в поддержку — поможем настроить за 2 минуты и подарим еще один бесплатный период."
                        if lang == "ru" else
                        "💎 Still looking for a premium VPN?\n\n"
                        "We are here to help! Message support — we will guide you and grant you another free trial."
                    )
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton("💬 Поддержка" if lang == "ru" else "🆘 Contact Support", url="https://t.me/mosaicsup"))
                    send_funnel_notification(telegram_id, "no_traffic_7d", text, markup)

            # --- PAID SUBSCRIPTIONS EXPIRY / UPSELLS (after trial) ---
            expire_at_raw = user_data.get("expireAt")
            if expire_at_raw:
                expire_dt = dateutil.parser.isoparse(expire_at_raw)
                if time_since_creation > datetime.timedelta(days=3):
                    is_active = (user_data.get("status") == "ACTIVE") and (expire_dt >= now)
                    
                    if is_active:
                        time_until_expiration = expire_dt - now
                        if time_until_expiration <= datetime.timedelta(hours=24) and time_until_expiration > datetime.timedelta(minutes=0):
                            expire_date_str = expire_dt.strftime("%d.%m.%Y")
                            notif_key = f"ends_soon_{expire_dt.strftime('%Y%m%d')}"
                            if notif_key not in sent_notifications:
                                text = (
                                    f"Ваша подписка заканчивается завтра {expire_date_str} ⏳\n\n"
                                    f"Продлите подписку заранее, чтобы не потерять доступ. Все настройки сохранятся автоматически."
                                    if lang == "ru" else
                                    f"Your subscription is expiring tomorrow {expire_date_str} ⏳\n\n"
                                    f"Renew your subscription in advance to keep your access uninterrupted. All configurations will remain."
                                )
                                markup = types.InlineKeyboardMarkup()
                                markup.row(types.InlineKeyboardButton("🔁 Продлить подписку" if lang == "ru" else "🔁 Renew", callback_data="show_tariffs"))
                                send_funnel_notification(telegram_id, notif_key, text, markup)
                                
                        # Family upsell: 30 days active
                        if time_since_creation >= datetime.timedelta(days=30) and "family_upsell" not in sent_notifications:
                            text = (
                                "👨‍👩‍👧‍👦 Подключите близких — семейный тариф на 6 устройств!\n\n"
                                "Одна подписка на всю семью. Это намного выгоднее и удобнее, чем платить за каждого отдельно."
                                if lang == "ru" else
                                "👨‍👩‍👧‍👦 Connect your family members — Family Plan supports 6 devices!\n\n"
                                "Share a single subscription. Much more economical and easier than paying for everyone separately."
                            )
                            markup = types.InlineKeyboardMarkup()
                            markup.row(types.InlineKeyboardButton("📋 Узнать подробнее" if lang == "ru" else "📋 Details", url="https://t.me/mosaicsup"))
                            send_funnel_notification(telegram_id, "family_upsell", text, markup)

                        # Annual upsell: 60 days active
                        if time_since_creation >= datetime.timedelta(days=60) and "annual_upsell" not in sent_notifications:
                            text = (
                                "💰 Платите за год — экономьте до 50% стоимости!\n\n"
                                "Вы пользуетесь Mosaic VPN уже 2 месяца. Годовой тариф обойдётся вам в разы дешевле помесячной оплаты!"
                                if lang == "ru" else
                                "💰 Pay annually — save up to 50%!\n\n"
                                "You've been with Mosaic VPN for 2 months. The annual plan costs significantly less than monthly payments!"
                            )
                            markup = types.InlineKeyboardMarkup()
                            markup.row(types.InlineKeyboardButton("💎 Годовой тариф" if lang == "ru" else "💎 Annual Plan", callback_data="show_tariffs"))
                            send_funnel_notification(telegram_id, "annual_upsell", text, markup)
                    else:
                        time_since_expiration = now - expire_dt
                        
                        # Immediately after expiry (0 to 24h)
                        if time_since_expiration >= datetime.timedelta(minutes=0) and time_since_expiration < datetime.timedelta(hours=24) and "sub_expired_imm" not in sent_notifications:
                            text = (
                                "⏰ Ваша подписка закончилась, VPN отключён.\n\n"
                                "Продлите баланс — всё заработает мгновенно. Все ваши настройки сохранены, ничего переподключать не потребуется."
                                if lang == "ru" else
                                "⏰ Your subscription has expired, VPN is disabled.\n\n"
                                "Renew your balance — connection resumes instantly. Your client configurations are preserved, no extra steps."
                            )
                            markup = types.InlineKeyboardMarkup()
                            markup.row(types.InlineKeyboardButton("🔁 Продлить подписку" if lang == "ru" else "🔁 Renew", callback_data="show_tariffs"))
                            send_funnel_notification(telegram_id, "sub_expired_imm", text, markup)

                        # 24 hours after expiry
                        elif time_since_expiration >= datetime.timedelta(hours=24) and time_since_expiration < datetime.timedelta(days=7) and "sub_expired_24h" not in sent_notifications:
                            text = (
                                "VPN всё ещё отключён ⏳\n\n"
                                "Мы бережно храним ваши настройки на сервере — просто продлите подписку в боте, и интернет снова станет свободным."
                                if lang == "ru" else
                                "VPN is still offline ⏳\n\n"
                                "We are still keeping your configs safe — simply renew your subscription to restore free web access."
                            )
                            markup = types.InlineKeyboardMarkup()
                            markup.row(types.InlineKeyboardButton("🔁 Продлить подписку" if lang == "ru" else "🔁 Renew", callback_data="show_tariffs"))
                            send_funnel_notification(telegram_id, "sub_expired_24h", text, markup)

                        # 7 days after expiry
                        elif time_since_expiration >= datetime.timedelta(days=7) and "sub_expired_7d" not in sent_notifications:
                            text = (
                                "👋 Давно не виделись.\n\n"
                                "Ваш профиль в Mosaic VPN готов к работе — продлите подписку в один клик и вернитесь к безопасному интернету."
                                if lang == "ru" else
                                "👋 Long time no see.\n\n"
                                "Your Mosaic VPN profile is ready — renew your subscription in one click to resume safe browsing."
                            )
                            markup = types.InlineKeyboardMarkup()
                            markup.row(types.InlineKeyboardButton("🔁 Продлить подписку" if lang == "ru" else "🔁 Renew", callback_data="show_tariffs"))
                            send_funnel_notification(telegram_id, "sub_expired_7d", text, markup)

            # --- WEEKLY REFERRAL PROMO ---
            if time_since_creation > datetime.timedelta(days=3):
                cursor.execute(
                    "SELECT sent_at FROM notification_history WHERE telegram_id = ? AND notification_type = 'weekly_ref_promo' ORDER BY id DESC LIMIT 1",
                    (telegram_id,)
                )
                last_ref_promo = cursor.fetchone()
                send_promo = False
                if not last_ref_promo:
                    send_promo = True
                else:
                    last_promo_dt = dateutil.parser.isoparse(last_ref_promo[0])
                    if now - last_promo_dt >= datetime.timedelta(days=7):
                        send_promo = True
                
                if send_promo:
                    username_clean = username.replace("tg_", "")
                    cursor.execute("SELECT username FROM users WHERE telegram_id = ?", (telegram_id,))
                    db_name_row = cursor.fetchone()
                    display_name = db_name_row[0] if db_name_row else username_clean
                    display_name = display_name.replace("_", "\\_").replace("*", "\\*")
                    
                    if lang == "ru":
                        text = (
                            f"🎁 **{display_name}, получите VPN бесплатно!**\n\n"
                            f"Пригласите друга в Mosaic VPN — когда он оплатит подписку, вы **ОБА** получите бонусные дни!\n\n"
                            f"```\n"
                            f" FRIEND PAYS · 10 → +10 FOR BOTH\n"
                            f" FRIEND PAYS · 30 → +30 FOR BOTH\n"
                            f" FRIEND PAYS · 90 → +90 FOR BOTH\n"
                            f"```\n"
                            f"• Друг оплатил 10 дней → **+10 дней** вам и другу!\n"
                            f"• Друг оплатил 30 дней → **+30 дней** вам и другу!\n"
                            f"• Друг оплатил 90 дней → **+90 дней** вам и другу!\n\n"
                            f"Без ограничений — приглашайте сколько угодно!\n\n"
                            f"Нажмите кнопку ниже, чтобы получить реферальную ссылку."
                        )
                        btn_link = "Получить реферальную ссылку"
                        btn_tariffs = "Тарифы"
                    else:
                        text = (
                            f"🎁 **{display_name}, get VPN for free!**\n\n"
                            f"Invite a friend to Mosaic VPN — when they pay, you **BOTH** get reward days!\n\n"
                            f"✅ **Bonus matches subscription bought:**\n"
                            f"• Friend bought 10 days → **+10 days** free!\n"
                            f"• Friend bought 30 days → **+30 days** free!\n"
                            f"• Friend bought 90 days → **+90 days** free!\n\n"
                            f"No limits — invite anyone!"
                        )
                        btn_link = "Get Referral Link"
                        btn_tariffs = "Tariffs"
                        
                    markup = types.InlineKeyboardMarkup()
                    markup.row(types.InlineKeyboardButton(btn_link, callback_data="ref_link"))
                    markup.row(types.InlineKeyboardButton(btn_tariffs, callback_data="show_tariffs"))
                    send_funnel_notification(telegram_id, "weekly_ref_promo", text, markup)

            # --- ABANDONED PAYMENTS ---
            cursor.execute("SELECT invoice_id, amount, days, created_at, status FROM invoices WHERE telegram_id = ? AND status = 'pending'", (telegram_id,))
            pending_invoices = cursor.fetchall()
            for invoice_id, amount, days, inv_created_str, inv_status in pending_invoices:
                inv_created_dt = dateutil.parser.isoparse(inv_created_str)
                time_since_invoice = now - inv_created_dt
                
                # 30 minutes without payment
                if time_since_invoice >= datetime.timedelta(minutes=30) and time_since_invoice < datetime.timedelta(hours=3):
                    notif_key = f"abandoned_pay_30m_{invoice_id}"
                    if notif_key not in sent_notifications:
                        text = (
                            f"⏰ Вы почти оформили подписку на {days} дней, но оплата не завершена\n\n"
                            f"Ссылка на оплату еще активна. Вы можете вернуться к счету и завершить платеж, это займет всего пару минут."
                            if lang == "ru" else
                            f"⏰ You almost purchased a {days}-day subscription, but the payment wasn't finished\n\n"
                            f"The invoicing link is still active. You can go back and complete the payment."
                        )
                        markup = types.InlineKeyboardMarkup()
                        markup.row(types.InlineKeyboardButton("💳 Перейти к оплате" if lang == "ru" else "💳 Pay / Create Invoice", callback_data="buy_subscription"))
                        send_funnel_notification(telegram_id, notif_key, text, markup)
                        
                # 3 hours without payment
                elif time_since_invoice >= datetime.timedelta(hours=3) and time_since_invoice < datetime.timedelta(hours=24):
                    notif_key = f"abandoned_pay_3h_{invoice_id}"
                    if notif_key not in sent_notifications:
                        text = (
                            f"🆘 Что-то пошло не так при оплате подписки на {days} дней?\n\n"
                            f"Если у вас возникли сложности — напишите нам в поддержку, поможем разобраться. Или попробуйте оформить заново."
                            if lang == "ru" else
                            f"🆘 Did something go wrong with your {days}-day subscription payment?\n\n"
                            f"If you encountered any issues — message our support. Or try creating a new invoice."
                        )
                        markup = types.InlineKeyboardMarkup()
                        markup.row(types.InlineKeyboardButton("🔄 Попробовать снова" if lang == "ru" else "🔄 Try Again", callback_data="buy_subscription"))
                        markup.row(types.InlineKeyboardButton("💬 Поддержка" if lang == "ru" else "🆘 Help / Support", url="https://t.me/mosaicsup"))
                        send_funnel_notification(telegram_id, notif_key, text, markup)
                        
        except Exception as ex:
            logger.error(f"Error checking user {telegram_id}: {ex}")
            
    conn.close()

def polling_notifications_loop():
    logger.info("Notification billing/funnel thread started.")
    while True:
        try:
            run_notifications_check()
        except Exception as e:
            logger.error(f"Error in notifications loop: {e}")
        time.sleep(60)

def uptime_monitor_loop():
    """Every 5 min: ping Remnawave API, record uptime, check alerts."""
    logger.info("Uptime monitor thread started.")
    while True:
        try:
            # Ping Remnawave API
            try:
                headers = api_get_headers()
                r = requests.get(f"{BASE_URL}/api/system/stats", headers=headers,
                                 timeout=10, proxies={"http": None, "https": None})
                online = (r.status_code == 200)
            except Exception:
                online = False
            uptime_record_ping(online)
            check_and_alert()
        except Exception as e:
            logger.error(f"Error in uptime loop: {e}")
        time.sleep(300)  # 5 minutes

def start_web_server():
    server_address = ("0.0.0.0", 12223)
    httpd = HTTPServer(server_address, StatsRequestHandler)
    logger.info("Web API server listening on 0.0.0.0:12223")
    httpd.serve_forever()

if __name__ == "__main__":
    init_db()
    _migrate_blocked_columns()
    
    # Configure Telegram commands and description details
    setup_bot_branding()
    
    # Start web server thread
    web_t = threading.Thread(target=start_web_server, daemon=True)
    web_t.start()
    
    # Start invoice polling thread
    poll_t = threading.Thread(target=polling_invoices_thread, daemon=True)
    poll_t.start()
    
    # Start notification/funnel thread
    notif_t = threading.Thread(target=polling_notifications_loop, daemon=True)
    notif_t.start()
    
    # Start uptime monitor thread (5-min pings + admin alerts)
    uptime_t = threading.Thread(target=uptime_monitor_loop, daemon=True)
    uptime_t.start()
    
    logger.info("Bot is starting polling...")
    # Robust polling loop — auto-restart on ConnectionError (Telegram API drops)
    # Uses exponential backoff to avoid hammering the API on persistent failures.
    poll_retry_delay = 3
    max_retry_delay = 60
    while True:
        try:
            # skip_pending=True discards updates that accumulated while the bot
            # was down — without this, every restart replays old messages and
            # users see duplicate responses to commands they sent hours ago.
            bot.infinity_polling(timeout=30, long_polling_timeout=20, skip_pending=True)
            poll_retry_delay = 3  # reset backoff after a clean run
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout,
                requests.exceptions.ReadTimeout) as e:
            logger.warning(f"Polling interrupted (network): {e}. Reconnecting in {poll_retry_delay}s...")
            time.sleep(poll_retry_delay)
            poll_retry_delay = min(poll_retry_delay * 2, max_retry_delay)
        except Exception as e:
            logger.error(f"Polling interrupted (unexpected): {e}. Reconnecting in {poll_retry_delay}s...")
            time.sleep(poll_retry_delay)
            poll_retry_delay = min(poll_retry_delay * 2, max_retry_delay)
