# ЗАДАЧА: Полное доведение экосистемы MosaicVPN (Telegram-бот, Remnawave, Сайт, Инфраструктура)

Ты — автономный senior full-stack AI-инженер. Твоя цель — полностью довести до ума экосистему MosaicVPN:
1. Завершить рефакторинг Telegram-бота (`bot.py`): сделать свободное пополнение баланса на любую сумму (1 рубль = 1 день, минимум 10 руб), обновить все клавиатуры, сообщения и скидочные воронки.
2. Синхронизировать тарифы и тексты на веб-сайте (`site/*.html`) и задеплоить на VPS.
3. Проверить и стабилизировать Remnawave (API, Nginx, PostgreSQL, бэкапы).
4. Выполнить полный цикл тестирования на хосте и VPS перед сдачей.

---

## 1. ДОСТУПЫ, ПУТИ И АРХИТЕКТУРА

### Хост (Windows):
- **Корень проекта:** `C:\Users\ANEN\mosaicvpn`
- **Telegram-бот:** `C:\Users\ANEN\mosaicvpn\bot\bot.py`
- **Тесты бота:** `C:\Users\ANEN\mosaicvpn\bot\test_*.py`
- **Веб-сайт (статика):** `C:\Users\ANEN\mosaicvpn\site\` (9 HTML-файлов)
- **Документация и планы:** `C:\Users\ANEN\mosaicvpn\docs\plans\`
- **SSH-ключ для VPS:** `C:\Users\ANEN\.ssh\id_ed25519_vitaly` (в MSYS bash: `~/.ssh/id_ed25519_vitaly`)

### Сервер VPS (Ubuntu 24.04):
- **IP:** `5.175.188.152` (Tailscale: `100.71.91.22`)
- **Пользователь:** `root`
- **Команда подключения:** `ssh -i ~/.ssh/id_ed25519_vitaly -o ConnectTimeout=15 root@5.175.188.152`
- **SCP загрузка:** `scp -i ~/.ssh/id_ed25519_vitaly <file> root@5.175.188.152:<dest>`

### Структура сервисов на VPS:
- **Telegram Bot:**
  - Директория: `/opt/mosaic-bot/`
  - Серверный скрипт: `/opt/mosaic-bot/bot.py`
  - База данных SQLite: `/opt/mosaic-bot/bot.db`
  - Виртуальное окружение: `/opt/mosaic-bot/venv/`
  - Файл секретов (chmod 600): `/etc/mosaic-bot.env` (`MOSAIC_BOT_TOKEN`, `MOSAIC_CRYPTO_PAY_TOKEN`, `MOSAIC_REMNAWAVE_TOKEN`)
  - Systemd юнит: `mosaic-bot.service`
  - Внутренний HTTP API порт бота: `12223` (слушает `0.0.0.0:12223`)
  - Управление: `systemctl restart mosaic-bot.service`, логи: `journalctl -u mosaic-bot.service -f`

- **Remnawave (Панель VPN & Docker):**
  - Директория: `/opt/remnawave/`
  - Конфиг Nginx: `/opt/remnawave/nginx.conf`
  - Скрипт бэкапов: `/opt/remnawave/backup-db.sh`
  - Папка бэкапов: `/opt/remnawave/backups/`
  - Контейнеры Docker:
    - `remnawave-nginx` (порты 80, 443)
    - `remnawave` (порт 3000 — API панели)
    - `remnawave-db` (PostgreSQL 16, порт 127.0.0.1:6767 -> 5432)
    - `remnawave-redis` (Redis, порт 6379)
    - `remnawave-subscription-page` (порт 3010)
    - `remnanode` (узел Xray/sing-box)

- **Веб-сайт (Landing & Cabinet):**
  - Путь на VPS: `/etc/letsencrypt/landing/`
  - Домен: `https://sub.zxc1x1.ru`
  - Панель Remnawave: `https://panel.zxc1x1.ru` / `https://host.zxc1x1.ru`
  - Nginx проксирует:
    - `/api/` и `/stats-api/` → `http://172.18.0.1:12223` (API бота)
    - `/*.html`, `/`, `/robots.txt` → статика из `/etc/letsencrypt/landing/`
    - `/pool-*`, `/direct`, `/de`, `/nl` и др. → локальные пулы sing-box

### Ключевые константы:
- **Telegram Bot Username:** `@mosaicvpnbot`
- **ID Владельца / Администратора:** `831992162`
- **Тарифная сетка:** `1 рубль = 1 день` (10 руб = 10 дней = 0.10 USDT, 30 руб = 0.30 USDT, 90 руб = 0.90 USDT, 365 руб = 3.65 USDT). Минимальная сумма пополнения: 10 руб (10 дней), максимальная: 365 руб (365 дней).

---

## 2. ТЕКУЩЕЕ СОСТОЯНИЕ И КРИТИЧЕСКИЙ БЛОКЕР

1. **Локальный `bot.py` (`C:\Users\ANEN\mosaicvpn\bot\bot.py`):**
   - Был начат рефакторинг тарифов: константа `PACKAGES` заменена на `RUB_PER_DAY = 1.0`, `USDT_RATE = 0.01`, `MIN_DAYS = 10`, `MAX_DAYS = 365`, `QUICK_PACKAGES = [10, 30, 90, 180]`, `_rub_to_usdt()`, `_package_label()`.
   - **БЛОКЕР:** В локальном `bot.py` остались старые вызовы `PACKAGES` в 6-7 местах (строки ~1573, ~1757, ~1765, ~1877, ~2319, ~2360), что приведёт к `NameError` при запуске.
   - Меню покупки и коллбэки требуют завершения реализации ввода произвольной суммы (`buy_custom`) через `bot.register_next_step_handler` или FSM.

2. **Прод на VPS (`/opt/mosaic-bot/bot.py`):**
   - Работает на предыдущем стабильном коммите (`c8c91bc`), сервис активен, ID админа, таймауты и защита от SQL-инъекций задеплоены.
   - Ожидает обновления на новую систему свободного пополнения после локальных тестов.

---

## 3. ПОШАГОВЫЙ ПЛАН ДОРАБОТОК

### ЭТАП 1: Доработка логики Telegram-бота (`bot.py`)

1. **Рефакторинг генерации клавиатуры покупки (`send_buy_menu`, `send_buy_discount_menu`):**
   - Для стандартного меню покупки формировать кнопки быстрых пресетов из `QUICK_PACKAGES = [10, 30, 90, 180]` (с текстом `_package_label(days, lang)` и `callback_data=f"buy_{days}"`).
   - Добавить кнопку **«✏️ Своя сумма» / «✏️ Custom amount»** с `callback_data="buy_custom"`.
   - Добавить кнопку **«🔙 Назад» / «🔙 Back»**.
   - Для меню со скидкой 50% (`send_buy_discount_menu`) аналогично: пресеты со скидкой `callback_data=f"buy_discount_{days}"` + `buy_discount_custom`.

2. **Обработчик свободной суммы (`buy_custom` и `buy_discount_custom`):**
   - По нажатию `buy_custom` бот отправляет запрос:
     `✏️ Введите количество дней (от 10 до 365):\n\n1 день = 1 рубль (например: 45 дней = 45 рублей = 0.45 USDT)`
   - Использовать `bot.register_next_step_handler(msg, process_custom_days_step, is_discount=False)`.
   - Валидация:
     - Проверка на целое число.
     - Диапазон: `MIN_DAYS <= days <= MAX_DAYS` (10..365).
     - При невалидном вводе выводить понятную ошибку и предлагать попробовать снова с кнопкой отмены.
   - При валидном вводе — формировать инвойс через `create_cryptopay_invoice()` с суммой `_rub_to_usdt(days * RUB_PER_DAY)` (или 50% при `is_discount`), сохранять инвойс через `save_invoice()` и отправлять кнопку оплаты `pay_title`.

3. **Обновление коллбэков покупки (`handle_buy_callback`, `handle_buy_discount_callback`):**
   - Поддержать произвольное целое количество дней `days = int(call.data.split("_")[1])`.
   - Расчёт суммы:
     - Обычный: `rub = days * RUB_PER_DAY`, `amount = _rub_to_usdt(rub)`, `months = round(days / 30.0, 2)`.
     - Скидка: `amount = round(_rub_to_usdt(rub) * 0.5, 2)`.
   - Генерация счёта CryptoBot и отправка инлайн-кнопки с URL оплаты.

4. **Полный аудит всех текстов и клавиатур бота:**
   - Главное меню:
     - `🛒 Пополнить` (вместо устаревшего «Купить подписку»)
     - `👤 Профиль`
     - `💎 Тарифы`
     - `📖 Инструкция`
     - `⚡ Бесплатные прокси`
     - `🎁 Пригласить друга`
     - `🎧 Поддержка`
     - `🌐 Язык / Language`
   - Текст тарифов (`menu_tariffs`): чётко указать «1 рубль = 1 день. Пополнение от 10 рублей до 365 рублей. До 5 устройств, VLESS xHTTP протокол».
   - Воронки уведомлений (`traffic_12h_dis`, `trial_expire_tomorrow`, `trial_expired`): обновить все кнопки и тексты, чтобы вели на актуальное меню пополнения.

---

### ЭТАП 2: Тестирование логики бота на хосте

1. **Дополнить тестовый набор в `C:\Users\ANEN\mosaicvpn\bot\`:**
   - Проверить и дополнить `test_bot_logic.py`, `test_payment_idempotency.py`, `test_web_cabinet.py`.
   - Добавить тесты для:
     - `_rub_to_usdt()` и `_package_label()` при различных суммах и скидках.
     - Валидации диапазона `MIN_DAYS` (10) .. `MAX_DAYS` (365).
     - Генерации инвойсов на произвольное количество дней (например, 17 дней, 45 дней, 120 дней).
     - Полного отсутствия старых ссылок на `PACKAGES` (проверка через AST).
2. **Запустить локальные тесты:**
   ```bash
   cd /c/Users/ANEN/mosaicvpn/bot
   python -c "import ast; ast.parse(open('bot.py', encoding='utf-8').read()); print('Syntax OK')"
   for t in test_link_codes test_link_endpoint test_web_cabinet test_payment_idempotency test_bot_logic; do
       printf "%-28s " "$t"
       python $t.py 2>&1 | tail -1
   done
   ```
   **Критерий успеха:** все тесты выводят `OK` без исключений.

---

### ЭТАП 3: Синхронизация и аудит веб-сайта (`site/`)

1. **Проверить 9 HTML-файлов в `C:\Users\ANEN\mosaicvpn\site\`:**
   - `index.html`, `cabinet.html`, `offer.html`, `terms.html`, `privacy.html`, `delivery.html`, `refund.html`, `contacts.html`, `docs.html`.
2. **Проверить соответствие:**
   - Ссылка на бота: строго `@mosaicvpnbot` (без `@mosaic_tf_bot`, `your_support_bot` и т.д.).
   - Тарифы: единый стандарт «1 рубль в сутки (0.01 USDT)», «3 дня бесплатно», «пополнение на любой срок от 10 дней».
   - Убедиться, что нет битых ссылок и заглушек.

---

### ЭТАП 4: Деплой на VPS и проверка сервисов

1. **Загрузить обновлённые файлы на VPS:**
   ```bash
   # Бот
   scp -i ~/.ssh/id_ed25519_vitaly C:/Users/ANEN/mosaicvpn/bot/bot.py root@5.175.188.152:/opt/mosaic-bot/bot.py

   # Статика сайта
   scp -i ~/.ssh/id_ed25519_vitaly C:/Users/ANEN/mosaicvpn/site/*.html root@5.175.188.152:/etc/letsencrypt/landing/
   ```

2. **Перезапустить бота и проверить статус:**
   ```bash
   ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 'systemctl restart mosaic-bot.service && sleep 2 && systemctl is-active mosaic-bot.service && journalctl -u mosaic-bot.service -n 20 --no-pager'
   ```

3. **Проверить Remnawave и веб-сервер:**
   ```bash
   ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
   ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 'curl -s -o /dev/null -w "Landing: %{http_code}\n" https://sub.zxc1x1.ru/'
   ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 'curl -s -o /dev/null -w "Cabinet: %{http_code}\n" https://sub.zxc1x1.ru/cabinet.html'
   ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 'curl -s -o /dev/null -w "Bot API: %{http_code}\n" http://127.0.0.1:12223/api/billing/profile?token=invalid'
   ```

---

### ЭТАП 5: Оффсайт-бэкап БД (Задача T0.2)

1. Проверить регулярный бэкап Remnawave в `/opt/remnawave/backups/`.
2. Настроить резервное копирование SQLite БД бота `/opt/mosaic-bot/bot.db` в архив бэкапов.
3. Скачать свежий бэкап на хост для проверки восстановимости (`sqlite3 bot_backup.db "PRAGMA integrity_check;"`).

---

## 4. ПРАВИЛА БЕЗОПАСНОСТИ И ОГРАНИЧЕНИЯ

1. **Секреты:** Никогда не выводить и не сохранять в память/коммиты токены (`MOSAIC_BOT_TOKEN`, `MOSAIC_CRYPTO_PAY_TOKEN`, `MOSAIC_REMNAWAVE_TOKEN`, пароли от БД). Заменять на `[REDACTED]`.
2. **Абсолютные пути:** Всегда использовать полные абсолютные пути (`C:\Users\ANEN\mosaicvpn\...` на Windows хосте, `/opt/...`, `/etc/...` на VPS).
3. **Zero Blind Hand-Off:** Не передавать работу пользователю без реального прогона тестов и проверки ответов HTTP / статусов systemd.
4. **Git:** После завершения всех этапов закоммитить изменения с понятным сообщением и запушить в `origin main`.
