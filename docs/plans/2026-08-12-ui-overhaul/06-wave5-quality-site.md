# Волна 5 — Качество, локализация, доступность, сайт

> Закрепляет результат. Волна 6 (сайт) внутри этого же файла, независима.

---

## T5.1 — Матрица responsive-тестов

**Приоритет:** P0 для качества. **Оценка:** 5 ч.

**Почему это первое в волне:** ✅ VERIFIED — в `flutter/test/` 11 файлов, среди них
`dashboard_desktop_test.dart`, и **ни одного теста на телефонной ширине**. Именно поэтому
баги с вашего скриншота дошли до релиза: CI был зелёный.

**Шаги.**
1. `test/responsive/` — прогон каждого из 15 экранов на 320 / 360 / 390 / 768 / 1280 dp
   при `textScaler` 1.0 и 1.3 (итого 10 конфигураций на экран).
2. Утверждения: `expect(tester.takeException(), isNull)` (ловит overflow) — и это минимум.
3. Дополнительно ловить разрыв слов: найти все `Text` с `maxLines: 1` и проверить, что
   их ширина ≥ ширины текста при данном стиле, иначе fail с указанием виджета.
4. Golden-файлы для 320 и 1280 на каждый экран.

**Приёмка:** `flutter test test/responsive/` → 150 конфигураций, все зелёные.
Вывод — в отчёт.

---

## T5.2 — CI: собирать и проверять всё, а не только Go

**Приоритет:** P0. **Оценка:** 4 ч.

**Проблема** ⚠️ SUBAGENT + ✅ VERIFIED по файлам:
`ci.yml` имеет jobs `test` (go vet + build + test -race), `build-windows`, `ui` (npm).
**Нет** `flutter analyze`, `flutter test`, сборки Android и Linux.
`release.yml` — один job `windows-installer`. Linux и Android собираются вручную с ноутбука.
Плюс `release.yml` качает sing-box **без проверки хэша** — supply-chain риск.

Хорошая база: `go test -race ./...` → 11 пакетов PASS, 0 гонок ⚠️ SUBAGENT (прогонял сам).

**Шаги.**
1. `ci.yml` + job `flutter`:
```yaml
  flutter:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: flutter } }
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.44.6', cache: true }
      - run: flutter pub get
      - run: flutter analyze --no-fatal-infos
      - run: flutter test
      - run: flutter build apk --release --split-per-abi
```
2. `ci.yml` + job `linux-bundle` (нужны `libgtk-3-dev`, `libayatana-appindicator3-dev`,
   `clang`, `cmake`, `ninja-build` — состав проверен при сборке в песочнице).
3. `release.yml`: добавить jobs `android-apk` и `linux-bundle`, чтобы релиз собирался
   автоматически, а не руками.
4. **Проверка хэша sing-box** при скачивании — `sha256sum -c` с зафиксированной суммой.
5. Единая версия: сейчас четыре разных ⚠️ SUBAGENT (daemon `0.1.0-dev`, Tauri `0.1.0`,
   Flutter `0.3.0`, NSIS `0.5.0`). Сделать один источник (`VERSION` в корне) и подставлять
   в сборки.

**Приёмка:** CI зелёный, в артефактах есть APK и Linux-бандл; версии во всех артефактах
совпадают.

---

## T5.3 — Доступность

**Приоритет:** P1. **Оценка:** 4 ч.

✅ VERIFIED: `grep -rc "Semantics(" lib/` → **пусто**;
`grep -rn "textScaler" lib/` → **пусто**.

**Шаги.**
1. `Semantics` на все интерактивные элементы и блоки данных (частично покрывается T1.5).
2. Размер зоны нажатия ≥ 48×48 — проверить кнопки-иконки: сейчас
   `IconButton(constraints: BoxConstraints(), padding: EdgeInsets.all(8))` в
   `_QuickStatusBar` даёт ~34×34, это ниже нормы для касания.
3. Прогон при `textScaler` 1.3 и 1.5.
4. Проверить контраст новых сочетаний — в теме уже есть посчитанные значения
   (`consoleError` «5.26:1 on bgInk»), продолжить эту практику и указывать контраст
   в комментарии к каждому новому токену.
5. Тест `test/a11y_test.dart` с `meetsGuideline(textContrastGuideline)` и
   `androidTapTargetGuideline`.

**Приёмка:** `flutter test test/a11y_test.dart` зелёный.

---

## T5.4 — Локализация (ru/en)

**Приоритет:** P1. **Оценка:** 6 ч.

✅ VERIFIED: `lib/l10n/` не существует, `AppLocalizations` не используется. При этом
`flutter_localizations` и `intl` в зависимостях **есть** — механизм заведён, но не задействован.
Строки вбиты в виджеты, преимущественно английские (`Stations & Sources`, `No Servers Found`,
`Engage Tunnel`), в двух файлах уже прорвался русский.

Продукт продаётся русскоязычной аудитории интерфейсом на английском. Это про конверсию,
не только про код.

**Шаги.**
1. `l10n.yaml` + `lib/l10n/app_en.arb` + `app_ru.arb`.
2. Вынести строки по одному экрану за коммит (иначе диффы нечитаемы).
3. Русский — основной язык по умолчанию, английский — второй.
4. Формат чисел, дат и сумм через `intl` с текущей локалью: «199 ₽», «12 авг. 2026»,
   «42 мс» — не «199.00 RUB» и не «42 ms».
5. Guard-тест: латинские/кириллические строковые литералы длиной > 3 символов в
   `lib/features/` → fail (кроме whitelist: имена протоколов, идентификаторы).

**Приёмка:** переключение языка в настройках меняет весь интерфейс; guard-тест зелёный.

---

## T5.5 — Сайт: мобильная вёрстка

**Приоритет:** P1. **Оценка:** 5 ч. **Независима от Flutter.**

**Проблемы** ✅ VERIFIED:
```
$ grep -n "@media" site/index.html
60: @media(max-width:1050px){ .nav-links{gap:12px} }
61: @media(max-width:920px){ .nav-links{display:none} }
135: @media (max-width:820px){ .price-wrap{grid-template-columns:1fr} }
```
Три медиа-запроса на весь лендинг. И главное: **гамбургер-меню отсутствует** ⚠️ SUBAGENT —
на телефоне все ссылки шапки просто исчезают, навигации нет вообще. Та же схема на
`cabinet.html` (760px), `docs.html` (860px), `terms.html`/`offer.html` (720px).

`.specs{overflow:hidden}` (строка 126) вместо `overflow-x:auto` → таблица протоколов
обрезается на узких экранах.

Заголовки безопасности отсутствуют ✅ VERIFIED: `curl -sI https://sub.zxc1x1.ru/` не отдаёт
ни `Cache-Control`, ни `Strict-Transport-Security`, ни `X-Frame-Options`, ни CSP.

**Шаги.**
1. Гамбургер-меню на всех 9 страницах (без JS-фреймворков — чистый CSS + `<details>` или
   минимальный JS, как в существующем стиле).
2. `.specs` → `overflow-x:auto`.
3. Тарифная таблица: на 360dp — карточки, не таблица.
4. Кнопки скачивания: `flex-wrap`, на narrow — в колонку на всю ширину.
5. Проверить все 9 страниц на 360 / 390 / 768 через browser-инструменты **со скриншотами**.
6. Заголовки в nginx: HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy,
   Cache-Control для статики. Осторожно — nginx в докере, конфиг `/opt/remnawave/nginx.conf`,
   перезагружать `docker exec remnawave-nginx nginx -s reload` (не пересоздавать контейнер).

**Приёмка:** скриншоты 9 страниц на 360dp; на каждой доступна навигация; `curl -sI` показывает
заголовки безопасности.

**Хорошее, что не трогать** ✅ VERIFIED: все 9 страниц отдают 200, HTTP→HTTPS 301 работает,
JS-ошибок в консоли нет, `/api/billing/*` без сессии корректно отдаёт 401
`{"error":"invalid or expired session"}` — утечки нет.

---

## T5.6 — Сайт: правдивость и модерация Lava

**Приоритет:** P0 частично (T0.5 — записка), остальное P1. **Оценка:** 3 ч.

1. **Записка для модератора на публичной оферте** — см. T0.5, это P0.
2. **Android** — см. T0.4.
3. Проверить остальные утверждения: «до 5 устройств», «3 дня бесплатно», «1 рубль в сутки»,
   «кроссплатформенный» — каждое подтвердить кодом или убрать. Слово «кроссплатформенный»
   при трёх карточках (Windows / Linux / Android ✅ VERIFIED) допустимо, но Android должен
   работать.
4. iOS/macOS на лендинге **не обещаны** ✅ VERIFIED — это хорошо, так и оставить, пока
   каталогов `ios/` и `macos/` нет.
5. Юридические страницы: реквизиты настоящие (НПД, ИНН `545113651604`) — **не менять и не
   выдумывать**. Проверить наличие: срок оказания услуги, порядок возврата, способ связи,
   цена в рублях.

**Приёмка:** таблица «утверждение → TRUE/MISLEADING/FALSE → что сделано» в отчёте.

---

## T5.7 — Go-демон: безопасность локального API

**Приоритет:** P1. **Оценка:** 4 ч.

⚠️ SUBAGENT (с моей проверкой ключевого пункта):
- ✅ VERIFIED `internal/api/server.go:1219`: при сбое `crypto/rand` токен =
  `fmt.Sprintf("fallback-%d", time.Now().UnixNano())` — предсказуем. Правильно: возвращать
  ошибку и не стартовать, а не выдавать слабый токен.
- Широкий CORS: эхо любого `Origin` → любая веб-страница на машине может дёргать локальный
  API демона. Ограничить белым списком или требовать заголовок с токеном без CORS вообще.
- `AllowLAN=true` по умолчанию → SOCKS слушает `0.0.0.0`. Небезопасный дефолт: сменить на
  `127.0.0.1`, а открытие в LAN сделать осознанным выбором.
- Нет ротации логов sing-box.
- 7 Go-пакетов без тестов.
- Lava live provider не реализован (см. `01-wave0-blockers.md`) — **без него монетизация
  не работает**, юридические страницы ведут в пустоту.

**Приёмка:** `go test -race ./...` зелёный; `grep -n "fallback-" internal/api/server.go`
→ пусто; дефолт `AllowLAN=false`.

---

## T5.8 — Распилить bot.py

**Приоритет:** P2. **Оценка:** 8 ч.

✅ VERIFIED: 3584 строки, 105 функций в одном модуле — БД, Remnawave API, платежи, тикеты,
рейтинги, промокоды, рассылки, рефералы, веб-эндпоинты.

Порядок (по модулю за коммит, три существующих теста не ломать):
```
bot/db.py          init_db, get_user, save_user, invoices, sessions
bot/remnawave.py   api_get_user, api_create_user, api_extend_user
bot/payments.py    cryptopay, polling_invoices_thread
bot/support.py     tickets, ratings, complaints
bot/referral.py    ref_stats, leaderboard, promo
bot/web.py         /api/session, /api/billing/*
bot/handlers/      telebot handlers
bot/bot.py         только сборка и запуск
```

Попутно (из отчёта субагента):
- 6 из 11 вызовов `requests` без `timeout` ✅ VERIFIED → поток может зависнуть навсегда
- `promo_apply` rate-limit определён, но нигде не вызывается
- `/broadcast` и `/buy` без rate-limit
- хардкод пароля PostgreSQL `postgres` (строка 2546)
- WAL не включён в SQLite при 5 демон-потоках → риск `database is locked`
- токен сессии в query-string URL (попадает в логи nginx)
- CORS wildcard `*` на `/stats-api`
- SQL-инъекция в `ref_stats_incr:996` — ❌ CORRECTED: субагент назвал P0, но `field` во всех
  4 вызовах литерал (`"paid"`, `"bonus_days_earned"`, `"clicks"`, `"joined"`), эксплуатировать
  нечем. Это отложенная мина, P2. Фикс на 2 минуты — whitelist имён колонок.

**Приёмка:** `python -m pytest bot/ -v` зелёный после каждого шага; `wc -l bot/bot.py` → < 300.
