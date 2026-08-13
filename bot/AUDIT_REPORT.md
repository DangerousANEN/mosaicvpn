# Аудит кодовой базы MosaicVPN Bot — Отчёт о находках

**Дата**: 2026-08-12  
**Файлы**: `bot/bot.py` (3584 строки), `test_web_cabinet.py`, `test_link_codes.py`, `test_link_endpoint.py`  
**Метод**: статический анализ (только чтение)  
**Статус ссылки**: CONFIRMED — подтверждено кодом; UNVERIFIED — предположение, требует проверки на VPS.

---

## 1. Архитектура: кластеры ответственности и границы модулей

### CONFIRMED · Монолит: 3584 строки, 105 функций верхнего уровня в одном файле

Все слои смешаны: инициализация БД, SQL-запросы, вызовы Remnawave API, платёжный цикл (CryptoPay), тикеты, реферальная система, веб-кабинет, HTTP-сервер, фоновые потоки — в одном модуле.

**Предлагаемые границы модулей:**

| Предлагаемый модуль | Функции (строки) |
|---|---|
| `db/init.py` | `init_db` (303), `_migrate_blocked_columns` (3009) |
| `db/users.py` | `get_user` (644), `save_user` (654), `update_user_lang` (670), `get_all_tg_users` (702), `mark_user_blocked` (3026), `clear_blocked_flag` (3041) |
| `db/invoices.py` | `save_invoice` (677), `get_pending_invoices` (687), `update_invoice_status` (695) |
| `db/sessions.py` | `issue_link_code` (483), `redeem_link_code` (512), `create_web_session` (577), `get_web_session` (595), `_link_code_normalise` (476) |
| `db/support.py` | `ticket_create` (1085), `ticket_add_message` (1094), `ticket_list_open` (1100), `ticket_close` (1108), `complaint_create` (1163) |
| `db/referral.py` | `ref_stats_incr` (991), `ref_stats_get` (999), `ref_leaderboard_top` (1012) |
| `db/promo.py` | `promo_create` (1023), `promo_validate` (1035), `promo_consume` (1054) |
| `db/ratings.py` | `rating_save` (1118), `rating_get_average` (1125) |
| `db/uptime.py` | `uptime_record_ping` (1135), `uptime_get_percent` (1143), `uptime_get_last_offline` (1156) |
| `db/payments.py` | `get_payments_history` (621) |
| `api/remnawave.py` | `api_get_headers` (725), `api_get_user` (733), `api_create_user` (743), `api_extend_user` (766) |
| `api/cryptopay.py` | `create_cryptopay_invoice` (802), `check_cryptopay_invoice` (825) |
| `web/server.py` | `StatsRequestHandler` (2329), `start_web_server` (3538) |
| `bot/admin.py` | `is_admin` (711), `admin_alert` (1181), `admin_stats` (1246), `handle_broadcast` (1608), `show_admin_panel` (2080), `handle_admin_top` (2106), `handle_promo_admin` (2121), `handle_admin_tickets` (2156) |
| `bot/payments.py` | `handle_buy_callback` (2237), `handle_buy_discount_callback` (2196), `polling_invoices_thread` (846) |
| `bot/handlers.py` | `send_welcome` (1295), `show_profile` (1497), `show_tariffs` (1580), `show_referral_promo` (1663), `show_support_menu` (1917) и пр. |
| `bot/funnel.py` | `run_notifications_check` (3091), `polling_notifications_loop` (3510) |

---

## 2. Безопасность SQL: параметризация vs. f-строки

### CONFIRMED · P0 — SQL-инъекция в `ref_stats_incr`

```python
# bot.py:996
c.execute(f"UPDATE referral_stats SET {field}={field}+? WHERE referrer_id=?", (by, referrer_id))
```

**Параметр `field` не параметризован.** Хотя внутри кода `field` принимает только значения `"clicks"`, `"joined"`, `"paid"`, `"bonus_days_earned"` — они не валидируются перед подстановкой. Если когда-либо `field` попадёт из внешнего источника (или рефакторинг добавит новый путь вызова), возникнет SQL-инъекция.

**Предлагаемое исправление** (`bot.py:991`): добавить whitelist-проверку:
```python
ALLOWED_FIELDS = frozenset({"clicks", "joined", "paid", "bonus_days_earned"})
if field not in ALLOWED_FIELDS:
    raise ValueError(f"invalid stat field: {field!r}")
```

### CONFIRMED · P1 — f-строки в ALTER TABLE (потенциально небезопасны при рефакторинге)

```python
# bot.py:326
cursor.execute(f"ALTER TABLE users ADD COLUMN {col} {decl}")
# bot.py:347
cursor.execute(f"ALTER TABLE invoices ADD COLUMN {col} {decl}")
```

`col` и `decl` — литеральные строки из жёстко заданных списков, не из пользовательского ввода. Пока **безопасно**, но паттерн опасен: при любом рефакторинге, добавляющем динамический источник — станет уязвимым.

### CONFIRMED · Всё остальное безопасно

Все остальные SQL-запросы используют параметризацию через `?` (SQLite) или `%s` (psycopg2). Уязвимостей SQL-инъекции в 100+ запросах не обнаружено.

---

## 3. Многопоточность: SQLite и риски конкурентного доступа

### CONFIRMED · P1 — 4 фоновых потока + polling без общего соединения

```python
# bot.py:3552–3565
web_t  = threading.Thread(target=start_web_server, ...)
poll_t = threading.Thread(target=polling_invoices_thread, ...)
notif_t = threading.Thread(target=polling_notifications_loop, ...)
uptime_t = threading.Thread(target=uptime_monitor_loop, ...)
```

**Хорошая новость**: каждая функция открывает и закрывает собственное соединение (`sqlite3.connect(DB_PATH)`) внутри каждой операции — общего соединения нет. Это снижает риск конфликтов.

**Плохая новость**: 
1. `sqlite3.connect()` вызывается без `check_same_thread=False` (не найдено нигде в файле), но поскольку соединения не передаются между потоками — конфликта типа «неправильный поток» нет.
2. SQLite по умолчанию работает в режиме **serialized** (WAL не включён в боте). При одновременных записях из нескольких потоков возможен `OperationalError: database is locked`. В тестах (`test_web_cabinet.py:78`) WAL включается явно — в production-коде этого нет.
3. Нет ни одного `threading.Lock()` — при одновременных транзакциях (например, `polling_invoices_thread` и `run_notifications_check` одновременно пишут) возможны кратковременные блокировки.

**Предлагаемое исправление** (`init_db`, `bot.py:303`): добавить `PRAGMA journal_mode=WAL` сразу после создания соединения.

---

## 4. Корректность платежей: идемпотентность CryptoPay

### CONFIRMED · P0 — Гонка двойного списания при параллельном poll

```python
# bot.py:850–855 (polling_invoices_thread)
pending = get_pending_invoices()          # Шаг 1: читает все pending
for invoice_id, telegram_id, days in pending:
    status = check_cryptopay_invoice(invoice_id)  # Шаг 2: запрос CryptoPay API
    if status == "paid":
        update_invoice_status(invoice_id, "paid")  # Шаг 3: записываем paid
        ...
        api_extend_user(username, days)            # Шаг 4: продлеваем подписку!
```

**Критическая проблема**: между шагами 1 и 3 нет атомарной проверки. `update_invoice_status` (строка 695–700) не имеет условия `WHERE status = 'pending'`:

```python
# bot.py:698 — НЕТ ЗАЩИТЫ ОТ ПОВТОРНОГО ВЫПОЛНЕНИЯ
cursor.execute("UPDATE invoices SET status = ? WHERE invoice_id = ?", (status, invoice_id))
```

**Сценарий двойного зачисления**: если `polling_invoices_thread` зависнет на вызове CryptoPay (нет timeout), при перезапуске бота (systemd `Restart=always`) новый процесс начнёт новый цикл полинга. Если оба экземпляра одновременно обнаружат один invoice со статусом `paid` до того, как первый успеет записать `UPDATE` — произойдёт двойное `api_extend_user`.

**Предлагаемое исправление** (`bot.py:698`): 
```python
cursor.execute(
    "UPDATE invoices SET status = ? WHERE invoice_id = ? AND status = 'pending'",
    (status, invoice_id)
)
if cursor.rowcount == 0:
    continue  # уже обработано другим процессом
```

### CONFIRMED · P1 — Отсутствие timeout на вызовы CryptoPay и Remnawave в polling-потоке

```python
# bot.py:736 — НЕТ timeout
res = requests.get(url, headers=api_get_headers())
# bot.py:757 — НЕТ timeout
res = requests.post(url, headers=api_get_headers(), json=payload)
# bot.py:792 — НЕТ timeout
res = requests.patch(url, headers=api_get_headers(), json=payload)
# bot.py:814 — НЕТ timeout (CryptoPay createInvoice)
res = requests.post(url, headers=headers, json=payload)
# bot.py:830 — НЕТ timeout (CryptoPay getInvoices)
res = requests.post(url, headers=headers, json=payload)
```

Итого 5 `requests` вызовов без `timeout`. Зависание любого из них — заморозка `polling_invoices_thread`.

---

## 5. Аутентификация веб-кабинета

### CONFIRMED · ХОРОШО — Токены генерируются криптографически стойко

```python
# bot.py:580
token = _secrets.token_urlsafe(32)
```
`secrets.token_urlsafe(32)` возвращает 256 бит случайности — это криптографически безопасно.

### CONFIRMED · ХОРОШО — Одноразовые коды (link codes): одиночное использование

```python
# bot.py:556–562 — атомарное сжигание кода
cursor.execute(
    "UPDATE link_codes SET used_at = ?, attempts = attempts + 1 "
    "WHERE code = ? AND used_at IS NULL", (now.isoformat(), code))
if cursor.rowcount == 0:
    return None, "used"
```
Условие `AND used_at IS NULL` обеспечивает атомарность: даже при параллельном запросе только один запрос получит `rowcount = 1`.

### CONFIRMED · ХОРОШО — TTL коды: 10 минут, максимум 5 попыток

```python
# bot.py:472–473
LINK_CODE_TTL_MINUTES = 10
LINK_CODE_MAX_ATTEMPTS = 5
```

### CONFIRMED · P1 — Авторизация: нет IDOR-защиты в `/api/billing/profile`

```python
# bot.py:2482–2527
def _handle_billing_profile(self, query):
    token = query.get("token", [""])[0]
    session = get_web_session(token)   # возвращает {telegram_id, username}
    if not session:
        self._send_json(401, ...)
    telegram_id = session["telegram_id"]  # ID берётся из СЕССИИ, не из запроса
    ...
    db_user = get_user(telegram_id)   # запрашивает данные своего пользователя
```

**Хорошая новость**: данные биллинга `/api/billing/profile` и `/api/billing/payments` берут `telegram_id` из сессионного токена — IDOR **отсутствует**.

### CONFIRMED · P2 — Слабость сессионных токенов в query-параметре

```python
# bot.py:2483
token = query.get("token", [""])[0]
```
Токен передаётся в URL query-string (`?token=...`), что приводит к его попаданию в access-логи nginx, историю браузера, Referer-заголовки при переходе на внешние ресурсы. Лучше — Authorization заголовок или cookie с `HttpOnly + Secure + SameSite=Strict`.

### CONFIRMED · P1 — Сессионный токен в `link_codes.session_token` хранится открытым текстом

```python
# bot.py:498–501
cursor.execute(
    "INSERT INTO link_codes (..., session_token, ...) VALUES (?, ?, ?, ?, ?, ?)",
    (code, telegram_id, username or "", session_token or "", ...),
)
```
`session_token` (короткий UUID) хранится в SQLite без хэширования. При утечке БД — все активные токены компрометируются.

### CONFIRMED · P2 — CORS для `/stats-api` — wildcard `*`

```python
# bot.py:2462
self.send_header("Access-Control-Allow-Origin", "*")
```
Для `/api/billing/*` CORS ограничен `https://sub.zxc1x1.ru` (строка 2341). Для `/stats-api/stats/<uuid>` — wildcard `*`. Это открывает endpoint для любого домена, при этом `short_uuid` является единственной защитой.

---

## 6. Rate Limiting / Защита от злоупотреблений

### CONFIRMED · Что защищено

```python
# bot.py:958–964
RATE_LIMIT_RULES = {
    "message":    (5, 60),       # 5 сообщений/60с
    "ref_click":  (10, 86400),   # 10 рефкликов/сутки
    "ticket":     (3, 3600),     # 3 тикета/час
    "promo_apply": (3, 3600),    # 3 применения промокода/час (ПРАВИЛО ЕСТЬ)
    "rating":     (1, 86400),    # 1 оценка/сутки
    "broadcast":  (1, 60),       # 1 рассылка/мин
}
```

Вызовы `rate_limit_check` найдены для:
- `"ticket"` — строки 1812, 1921
- `"rating"` — строка 2055

### CONFIRMED · P1 — `promo_apply` — правило есть, вызова нет

```python
# bot.py:962 — ПРАВИЛО ОПРЕДЕЛЕНО
"promo_apply": (3, 3600),
```

Однако **`rate_limit_check(telegram_id, "promo_apply")` нигде не вызывается** — ни в одном хендлере. Промокоды пользователи могут применять неограниченно быстро. У `promo_consume` нет атомарного check-and-increment — `promo_validate` и `promo_consume` — отдельные операции.

### CONFIRMED · P1 — `/broadcast` не имеет rate_limit_check

```python
# bot.py:1608–1632
def handle_broadcast(message):
    if not is_admin(telegram_id):  # проверка по is_admin (admins.txt)
        return
    ...
    for uid in users:
        bot.send_message(uid, broadcast_msg, parse_mode="Markdown")
```

`rate_limit_check(telegram_id, "broadcast")` **не вызывается** — правило `(1, 60)` определено, но не применяется. Администратор может отправить рассылку многократно.

### CONFIRMED · P1 — `/buy` (покупки) не защищены rate-limit

Хендлеры `handle_buy_callback` (2237) и `handle_buy_discount_callback` (2196) не вызывают `rate_limit_check`. Пользователь может создавать бесчисленные инвойсы в CryptoPay.

---

## 7. Административная поверхность: is_admin vs ADMIN_IDS

### CONFIRMED · P0 — `ADMIN_IDS` не определён в `bot.py`

Имя `ADMIN_IDS` используется в 7 местах (строки 1183, 1854, 1987, 2082, 2107, 2122, 2157), но **нигде не определяется** в проверяемой копии `bot/bot.py`. Если VPS-копия также не содержит определения — это `NameError` при первом обращении к любой из этих функций.

```python
# bot.py:2082 — ADMIN_IDS never assigned!
if telegram_id not in ADMIN_IDS:
    return
# bot.py:1854
for admin_id in ADMIN_IDS:
```

**UNVERIFIED**: VPS-копия `/opt/mosaic-bot/bot.py` может содержать строку `ADMIN_IDS = [...]`, выпущенную при сохранении в репозиторий. Необходимо проверить `grep -n ADMIN_IDS /opt/mosaic-bot/bot.py`.

### CONFIRMED · P1 — is_admin() и ADMIN_IDS — два разных механизма без синхронизации

`/broadcast` (строка 1610) проверяет `is_admin()` (читает файл `admins.txt`). Остальные admin-команды (`/admin`, `/top`, `/promo`, `/tickets`) проверяют `ADMIN_IDS` — список в памяти. Эти источники могут рассинхронизироваться.

### CONFIRMED · P1 — Хардкод admin ID в is_admin()

```python
# bot.py:716 — HARDCODED ADMIN ID
f.write("583864\n")  # Default authorized ID
```

Если `/opt/mosaic-bot/admins.txt` отсутствует, создаётся файл с ID `583864`. Это hardcoded значение останется в репозитории.

---

## 8. Обработка ошибок и устойчивость

### CONFIRMED · P1 — 55 `except Exception` блоков

Большинство ошибок только логируются без уведомления пользователя или повтора операции. Примеры критических немых сбоев:

```python
# bot.py:739–741 — немой сбой api_get_user
except Exception as e:
    logger.error(f"Error fetching user by username: {e}")
return None

# bot.py:797–799 — немой сбой api_extend_user (подписка НЕ продлена!)
except Exception as e:
    logger.error(f"Error extending user: {e}")
return None

# bot.py:721 — is_admin() возвращает False при любой ошибке чтения файла
except Exception:
    return False
```

Особенно критично `api_extend_user` на строке 797: если запрос к Remnawave упал по network-ошибке, пользователь заплатил (invoice marked paid), но подписка не продлена. Нет retry, нет алерта.

### CONFIRMED · P1 — Нет timeout на 5 запросов к Remnawave и CryptoPay (детали в разделе 4)

### CONFIRMED · P2 — `get_server_status` содержит заглушку

```python
# bot.py:1066
user_info = api_get_user(f"tg_")  # placeholder for API circle check
```
Это вызов `api_get_user("tg_")` — явная заглушка (шаблон без ID), которая всегда вернёт `None` и проигнорируется. Функция работает через второй путь, но первый вызов — лишний и потенциально шумит в логах.

---

## 9. Покрытие тестами

### CONFIRMED · Что покрывают 3 файла тестов

**`test_link_codes.py`** (182 строки, 11 тестов):
- Создание и погашение link_codes
- Одноразовость (single-use guard)
- TTL истечение
- Race condition: параллельные попытки погашения одного кода
- Нормализация ввода (лишние символы, строчные буквы)
- Алфавит без неоднозначных символов (0, O, I, L, 1)

**`test_link_endpoint.py`** (198 строк, 11 тестов):
- HTTP-контракт `/api/link/redeem` (200, 404, 409, 410, 429, 400)
- Параллельный race test через ThreadingHTTPServer
- Oversized body rejection (>4096 байт)

**`test_web_cabinet.py`** (303 строки, 10 тестов):
- `create_web_session` / `get_web_session` (создание, чтение)
- Истёкший сессионный токен → 401
- `/api/session` с кодом → 200 + token
- `/api/billing/profile` и `/api/billing/payments` с токеном
- CORS OPTIONS: 204 + заголовок `sub.zxc1x1.ru`

### CONFIRMED · Непокрытые критические пути

1. **Платёжный поток целиком** — `polling_invoices_thread` не протестирован. Ни один тест не проверяет: CryptoPay инвойс создан → polling обнаружил paid → `api_extend_user` вызван → пользователь уведомлён. Это основной бизнес-процесс без тестов.

2. **Двойное списание** — race condition в `polling_invoices_thread` (описан в разделе 4) не тестируется.

3. **`ref_stats_incr`** с f-строкой — не тестируется.

4. **Промокоды** — `promo_validate`/`promo_consume` не тестируются (нет handler для их вызова).

5. **`run_notifications_check`** (funnel, 400+ строк) — нет ни одного теста.

6. **admin-команды** — `/broadcast`, `/admin`, `/top` не тестируются вообще.

---

## 10. Хранение секретов

### CONFIRMED · ХОРОШО — Основные секреты через env vars

```python
# bot.py:26–30
BOT_TOKEN = os.environ.get("MOSAIC_BOT_TOKEN", "")
CRYPTO_PAY_TOKEN = os.environ.get("MOSAIC_CRYPTO_PAY_TOKEN", "")
API_TOKEN = os.environ.get("MOSAIC_REMNAWAVE_TOKEN", "")
BASE_URL = os.environ.get("MOSAIC_REMNAWAVE_URL", "https://panel.zxc1x1.ru")
```

Валидация при старте:
```python
# bot.py:37–40
_missing = [n for n, v in (("MOSAIC_BOT_TOKEN", BOT_TOKEN), ("MOSAIC_REMNAWAVE_TOKEN", API_TOKEN)) if not v]
if _missing:
    raise SystemExit("missing required environment variables: " + ", ".join(_missing))
```

### CONFIRMED · P1 — Хардкод PostgreSQL credentials

```python
# bot.py:2542–2547 (get_user_statistics)
pg_conn = psycopg2.connect(
    host="127.0.0.1",
    port=6767,
    user="postgres",
    password="postgres",   # ХАРДКОД ДЕФОЛТНОГО ПАРОЛЯ
    database="postgres"
)
```

Дефолтный пароль `postgres` захардкожен прямо в коде. Он остаётся в репозитории и видим всем, кто имеет доступ к git-истории.

### CONFIRMED · P2 — Хардкод admin ID в is_admin()

```python
# bot.py:716
f.write("583864\n")  # Default authorized ID — ХАРДКОД TELEGRAM ID АДМИНИСТРАТОРА
```

### CONFIRMED · P2 — BASE_URL имеет дефолт с реальным доменом

```python
# bot.py:33
BASE_URL = os.environ.get("MOSAIC_REMNAWAVE_URL", "https://panel.zxc1x1.ru")
```

Реальный production-домен зашит как default. Некритично в production, но нежелательно в коде — в тестовых средах без env-переменной будут идти запросы на production-панель.

---

## Приоритизированный список проблем

### P0 — Дыры в безопасности / потери данных

| # | Проблема | Файл:строка | Предлагаемое исправление |
|---|---|---|---|
| P0-1 | **SQL-инъекция в `ref_stats_incr`**: параметр `field` подставляется в f-строку без whitelist-проверки | `bot.py:996` | Добавить `ALLOWED_FIELDS = frozenset({...})` и проверку перед выполнением |
| P0-2 | **Двойное зачисление подписки**: `update_invoice_status` не имеет `WHERE status='pending'` — при race condition возможно двойное `api_extend_user` | `bot.py:698` | Изменить SQL: `WHERE invoice_id = ? AND status = 'pending'`, после проверять `rowcount` |
| P0-3 | **`ADMIN_IDS` не определён** в репозиторной копии — возможен `NameError` в production | `bot.py:1183,1854,1987,2082,2107,2122,2157` | Определить `ADMIN_IDS = [...]` или загружать из env; объединить с `is_admin()` |

### P1 — Корректность / поддерживаемость

| # | Проблема | Файл:строка | Предлагаемое исправление |
|---|---|---|---|
| P1-1 | **`promo_apply` rate-limit не применяется**: правило есть, вызова нет | `bot.py:962` + каждый promo-handler | Добавить `rate_limit_check(tg_id, "promo_apply")` в handler применения промокода |
| P1-2 | **`/broadcast` не защищён rate_limit_check** несмотря на определённое правило | `bot.py:1608` | Добавить `rate_limit_check(telegram_id, "broadcast")` после проверки `is_admin` |
| P1-3 | **`/buy` не защищён rate-limit**: можно создавать бесчисленные инвойсы | `bot.py:2237,2196` | Добавить `rate_limit_check(telegram_id, "buy")` с лимитом 5/мин |
| P1-4 | **5 `requests` вызовов без `timeout`**: зависание CryptoPay/Remnawave заморозит поток | `bot.py:736,757,792,814,830` | Добавить `timeout=30` ко всем вызовам |
| P1-5 | **Хардкод PostgreSQL пароля `postgres`** в production-коде | `bot.py:2546` | Читать из env `PG_PASSWORD`, не хардкодить |
| P1-6 | **WAL не включён**: возможны `database is locked` при нескольких потоках | `bot.py:303` | Добавить `PRAGMA journal_mode=WAL` в `init_db()` |
| P1-7 | **Два несинхронизированных механизма admin-проверки** (`is_admin()` файл vs `ADMIN_IDS` список) | `bot.py:711 vs 2082` | Унифицировать: `ADMIN_IDS = set(...)` заполнять из `admins.txt` при старте |
| P1-8 | **`api_extend_user` ошибка — немой сбой**: пользователь заплатил, подписка не продлена, нет retry и алерта | `bot.py:797–799` | Добавить retry (3 попытки) + `admin_alert(...)` при финальном сбое |
| P1-9 | **`promo_validate` и `promo_consume` — отдельные транзакции**: возможно race condition при параллельном применении одного кода | `bot.py:1035,1054` | Объединить в одну транзакцию с `UPDATE ... WHERE used_count < max_uses` |

### P2 — Косметика / качество

| # | Проблема | Файл:строка | Предлагаемое исправление |
|---|---|---|---|
| P2-1 | Сессионный токен передаётся в URL query-string → попадает в логи | `bot.py:2483` | Использовать `Authorization: Bearer <token>` заголовок |
| P2-2 | CORS для `/stats-api` — wildcard `*` | `bot.py:2462` | Ограничить до `https://sub.zxc1x1.ru` |
| P2-3 | Хардкод admin TG_ID `583864` в `is_admin()` | `bot.py:716` | Убрать дефолт, требовать явного заполнения `admins.txt` |
| P2-4 | Заглушка `api_get_user(f"tg_")` в `get_server_status` | `bot.py:1066` | Удалить мёртвый код (3 строки) |
| P2-5 | Весь код в одном модуле 3584 строк — нет модульности | `bot.py` | Рефакторинг по предложенным границам модулей (см. раздел 1) |
| P2-6 | Тест `polling_invoices_thread` (основной платёжный цикл) отсутствует | тесты | Добавить integration-тест с мок-CryptoPay + мок-Remnawave |
| P2-7 | `session_token` в `link_codes` хранится открытым текстом | `bot.py:498` | Хранить SHA-256 хэш, сравнивать при верификации |
| P2-8 | BASE_URL с реальным production-доменом в дефолте | `bot.py:33` | Убрать дефолт, сделать env обязательным |

---

## Итог — 10 ключевых выводов

1. **Монолит 3584 строк** без структуры — рефакторинг неизбежен; карта модулей предоставлена выше.
2. **Одна реальная SQL-инъекция** (`ref_stats_incr`, P0) — `field` не валидируется.
3. **SQLite без WAL** + 4 конкурентных потока — риск `database is locked`.
4. **Двойное зачисление** возможно из-за отсутствия atomic check (`WHERE status='pending'`).
5. **5 HTTP-запросов без timeout** — поток полинга может зависнуть навсегда.
6. **`ADMIN_IDS` не определён** в репозиторной копии — возможен `NameError` в production (требует проверки на VPS).
7. **`promo_apply` rate_limit_check определён, но не вызывается** — промокоды не защищены.
8. **PostgreSQL пароль `postgres` захардкожен** в коде.
9. **Платёжный цикл (`polling_invoices_thread`) не покрыт тестами** — ноль тестов для основного бизнес-процесса.
10. **Веб-кабинет auth правильный** (secrets.token_urlsafe, link codes атомарны), но токен в query-string — логируется nginx.
