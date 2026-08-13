# MosaicVPN — сводный план доработок сервиса

> Составлен 2026-08-12 по итогам аудита пятью субагентами (VPS / бот / Flutter / Go-демон / сайт).
> Каждый пункт помечен: ✅ VERIFIED — подтверждён реальным выводом команды; ⚠️ SUBAGENT — заявлен субагентом, лично не перепроверялся; ❌ CORRECTED — заявление субагента исправлено после проверки.

**Цель:** довести сервис из «работает у автора» до «продаётся незнакомцам и не врёт им».

**Аудит проведён:** 5 параллельных субагентов, 168 API-вызовов, 648 с. Артефакты:
- `C:\Users\ANEN\mosaic-vpn-audit-2026-08-12.md` — VPS (25 КБ)
- `C:\Users\ANEN\mosaicvpn\bot\AUDIT_REPORT.md` — бот (30 КБ)
- `C:\Users\ANEN\mosaicvpn\AUDIT_ANDROID_CROSSPLATFORM.md` — Flutter (36 КБ)
- `C:\Users\ANEN\mosaicvpn\AUDIT_REPORT.md` — Go + CI (33 КБ)
- сайт — субагент упал на 429 после 50 итераций, находки восстановлены из транскрипта и доперепроверены мной

---

## Три вещи, которые обманывают пользователя прямо сейчас

Это не багрепорт, это про доверие. Каждая — оплаченная функция, которой нет.

### 1. Kill Switch — кнопка, которая ничего не делает ✅ VERIFIED

```bash
$ grep -rn "internal/killswitch" --include=*.go . | grep -v "^./internal/killswitch/"
>>> НИ ОДНОГО ИМПОРТА ВНЕ ПАКЕТА <<<
```

Пакет `internal/killswitch/` содержит полноценный WFP-код и свой тест. Его **не импортирует ни один файл** за пределами самого пакета. Ни `state.go`, ни `singbox_backend.go` не вызывают `Enable`/`Disable`. В UI переключатель горит красным «Kill Switch armed», в панели написано «Kill switch is armed» — при обрыве туннеля трафик утекает в открытую сеть.

Для VPN это худший класс дефекта: пользователь принимает решения о своей безопасности, опираясь на индикатор, который врёт.

### 2. Android APK не может построить туннель ✅ VERIFIED

`flutter/android/app/src/main/AndroidManifest.xml` — только `INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`. Нет `BIND_VPN_SERVICE`, нет `<service>`, нет `VpnService`. Нативного кода — только `MainActivity.kt`.

Хуже, чем просто «не работает» ⚠️ SUBAGENT: `daemon_launcher.dart:68` вызывает `Process.start('mosaicd.exe')` без Android-гарда, падает молча, и клиент **сваливается в `MockDaemonApi`** — то есть рисует фиктивное подключение. Приложение показывает «Connected» при нулевом туннеле. Ваши скриншоты с рассыпавшимся текстом — это косметика поверх этого.

Сайт при этом пишет про APK: *«Тот же интерфейс и подписки, что и на десктопе, адаптированные под сенсорный ввод»* ✅ VERIFIED (`site/index.html:280`). Ни одно из трёх утверждений не выполняется.

### 3. Приём платежей через Lava не реализован ✅ VERIFIED

```
internal/billing/lava.go:196  return nil, errors.New("lava live provider not fully implemented")
internal/billing/lava.go:203  return nil, errors.New("lava live provider not fully implemented")
internal/billing/lava.go:222  return errors.New("lava live provider not fully implemented")
```

`CreatePayment`, `GetPaymentStatus`, `MarkPaid` — заглушки. По умолчанию активен mock ⚠️ SUBAGENT. То есть недели работы над юридическими страницами под модерацию Lava ведут к платёжному коду, которого нет. Реально работают только CryptoPay в боте.

---

## P0 — Блокеры (сегодня–завтра)

### 0.1 Диск VPS: 88%, journald без лимита ✅ VERIFIED

```bash
$ df -h /                       → 21G/24G, 3.0G свободно, 88%
$ du -sh /var/log/journal       → 2.3G
$ grep -vE "^#|^$" /etc/systemd/journald.conf → только "[Journal]", лимитов НЕТ
```

Через 1–2 недели диск переполнится → встанет `remnawave-db` (Postgres) → умрут все подписки. Плюс ⚠️ SUBAGENT: 5 orphaned Docker volumes (251 МБ), `/opt/flutter` весом 1.8 ГБ на **боевом VPN-сервере**, логи watchdog/selector/autonomous_cron не ротируются.

```bash
ssh ... 'journalctl --vacuum-size=300M'
ssh ... 'printf "SystemMaxUse=300M\nSystemMaxFileSize=50M\nMaxRetentionSec=14day\n" >> /etc/systemd/journald.conf && systemctl restart systemd-journald'
ssh ... 'docker volume prune -f; docker image prune -af --filter until=168h'
ssh ... 'rm -rf /opt/flutter'   # ← только после подтверждения, что там нет нужного
```
Критерий приёмки: `df -h /` ≤ 70%. Затем cron-сторож, который молчит при норме и пишет только при >85%.

### 0.2 Бэкапы БД только локально ✅ VERIFIED

Ежечасные дампы в `/opt/remnawave/backups` (15 МБ, 30 дней) лежат на том же диске, который на 88% полон. Хорошая новость ⚠️ SUBAGENT: дамп читается (`pg_restore --list` → 228 TOC entries, формат CUSTOM), то есть бэкапы не битые.

Сделать: ежедневный `scp` на локальную машину + проверка `pg_restore --list` после каждой тяги. Дампы в сторонние облака не заливать — там персональные данные.

### 0.3 Kill Switch: либо подключить, либо убрать из UI

Развилка, нужно ваше решение:
- **A (честно и быстро):** убрать переключатель из UI и надпись «kill switch is armed», пока не работает. 1 час.
- **B (правильно):** подключить `internal/killswitch` к жизненному циклу подключения в `internal/state`. Плюс отдельная проблема ⚠️ SUBAGENT: WFP-сессия `DYNAMIC` удаляется ОС при выходе → **fail-OPEN при крэше демона**. Нужен fail-CLOSED и очистка правил при нечистом выходе. На Linux ⚠️ SUBAGENT `noop.go` возвращает успех вместо «не поддерживается» — то есть линуксовые пользователи тоже видят фиктивную защиту.

Оставлять как есть нельзя ни в каком варианте.

### 0.4 Android: снять APK с сайта либо сделать по-настоящему

- **A (30 минут, P0):** в `site/index.html:284` убрать ссылку на `.apk`, заменить карточку на «Android — в разработке», в описании GitHub Release пометить APK как нерабочий. Задеплоить, проверить `curl -I`.
- **B (отдельный спринт, 3–5 дней):** `gomobile bind` ядра sing-box в `.aar` → `MosaicVpnService.kt` (наследник `VpnService`, TUN через `Builder`, fd в libcore) → манифест с `BIND_VPN_SERVICE` + `intent-filter android.net.VpnService` + foreground-нотификация (иначе Android убьёт сервис) → `MethodChannel ru.mosaicvpn/tunnel` → в Dart развести `DaemonApi` на `HttpDaemonApi` (десктоп) и `ChannelDaemonApi` (Android) через уже существующий `AppPlatform.isMobile`.

Рекомендация: A сегодня, B спринтом. Продавать нерабочий клиент дороже, чем не иметь его.

### 0.5 Внутренняя записка для модератора опубликована на сайте ✅ VERIFIED

```bash
$ curl -s https://sub.zxc1x1.ru/offer.html | grep -c "notice-banner"   → 3
```
На живой публичной оферте висит:

> **Юридическое предупреждение для проверяющего / владельца:** … Перед приёмом платежей рекомендуется правовая проверка документа.

Это служебная заметка для вас, а видит её любой посетитель и модератор Lava. Текст буквально сообщает, что документ юридически не проверен. Удалить блок из `site/offer.html:200-206`, задеплоить.

Реквизиты на месте и настоящие ✅ VERIFIED (`Липский Никита Евгеньевич`, ИНН `545113651604`, НПД) — их не трогаю и не выдумываю.

### 0.6 Двойное зачисление подписки ✅ VERIFIED

```python
# bot/bot.py:698
cursor.execute("UPDATE invoices SET status = ? WHERE invoice_id = ?", (status, invoice_id))
```
Нет `AND status='pending'`. При перезапуске systemd (`Restart=always`) два прохода поллинга могут дважды вызвать `api_extend_user` по одному инвойсу. Аналогично ⚠️ SUBAGENT в Go: у Lava-вебхука нет идемпотентности, у YooKassa-вебхука нет ни проверки IP, ни HMAC.

Фикс: `WHERE invoice_id=? AND status='pending'` + проверять `rowcount` перед начислением.

---

## P1 — Эта неделя

### 1.1 Админ-панель и алерты мертвы ✅ VERIFIED (и это не то, что сказал субагент)

Субагент заявил «`ADMIN_IDS` не определён → всё упадёт с NameError». Проверил лично и на репо, и **на проде**:

```bash
$ grep -nE "ADMIN_IDS *=" /opt/mosaic-bot/bot.py   → ОПРЕДЕЛЕНИЯ НЕТ
$ cat /opt/mosaic-bot/admins.txt                   → файла нет
$ journalctl -u mosaic-bot --since "48 hours ago" | grep -c NameError  → 0
```

`ADMIN_IDS` используется в 7 местах и **нигде не определён**, ни локально, ни в проде. NameError в логах нет по простой причине: все пути обёрнуты в `try/except Exception`, ошибка глотается молча. Практический итог — `admin_alert()` (строка 1181) никогда не доставляет сообщения, а `check_and_alert()` крутится каждые 300 с впустую. **Сервис может лежать, и вы об этом не узнаете.** Команды `/admin`, `/top`, `/promo`, `/tickets` мертвы.

Отдельно: в файле живут **два несогласованных механизма админства** — рабочий `is_admin()` (читает `admins.txt`, дефолт ID `583864`) и сломанный `ADMIN_IDS`. Свести к одному.

### 1.2 SQL-инъекция в ref_stats_incr ❌ CORRECTED

Субагент назвал это P0. Проверил все точки вызова:

```python
# bot/bot.py:996
c.execute(f"UPDATE referral_stats SET {field}={field}+? WHERE referrer_id=?", (by, referrer_id))
# вызовы: "paid", "bonus_days_earned", "clicks", "joined" — все литералы (строки 891, 892, 1361, 1362)
```

`field` нигде не приходит от пользователя, эксплуатировать сейчас нечем. Это **отложенная мина**, а не активная дыра: P2. Фикс на 2 минуты — whitelist допустимых имён колонок.

### 1.3 Сеть VPS: firewall выключен, порты наружу ⚠️ SUBAGENT

- UFW disabled, fail2ban отсутствует
- Порты **3000** (remnawave backend) и **3010** (subscription-page) открыты в интернет; `ProxyCheckMiddleware` фиксирует прямые обращения — то есть панель уже щупают
- Certbot deploy-hook пуст → после автообновления сертификата nginx **не перезагрузится**, сайт отдаст просроченный TLS
- `$connection_upgrade "" close` ломает XHTTP-стриминг для VPN-клиентов
- Нет rate-limiting и security headers ✅ VERIFIED мной: `curl -sI https://sub.zxc1x1.ru/` → ни одного `Cache-Control`, `Strict-Transport-Security`, `X-Frame-Options`, `Content-Security-Policy`

Плюс находка, требующая вашего решения ⚠️ SUBAGENT: на боевом VPN-сервере рядом со стеком крутится **DePIN-фарм (Grass/Wynd Network)**. Он ест те же CPU/сеть/диск и повышает шанс попадания IP в чёрные списки. Это про надёжность платного сервиса — стоит развести по разным машинам.

### 1.4 Мобильный сайт: навигации нет вообще ⚠️ SUBAGENT

`site/index.html:61` → `@media(max-width:920px){ .nav-links{display:none} }`, и **гамбургер-меню отсутствует**. На телефоне все ссылки шапки просто исчезают. Та же схема на `cabinet.html` (760px), `docs.html` (860px), `terms.html`/`offer.html` (720px).

Всего на лендинге 3 медиа-запроса. `.specs{overflow:hidden}` (строка 126) вместо `overflow-x:auto` → таблица протоколов обрезается на узких экранах.

Хорошее: все 9 страниц отдают 200, HTTP→HTTPS 301 работает, JS-ошибок в консоли нет, `/api/billing/*` без сессии корректно отвечает 401 `{"error":"invalid or expired session"}` — утечки данных нет ✅ VERIFIED.

Исправление моей же более ранней ошибки: я говорил, что сайт обещает 5 платформ и врёт про iOS/macOS. Проверил — **на лендинге ровно три карточки: Windows, Linux, Android**, iOS и macOS не упоминаются. Ложное обещание там одно — про работающий Android.

### 1.5 Flutter: мобильный UX ⚠️ SUBAGENT

Уже сделано в рабочей копии (не закоммичено), субагент подтвердил корректность:
- `app_shell.dart` — breakpoint `size.width > 900` → `shortestSide > 600`
- `atlas_widgets.dart` — `SectionHeader` складывается в колонку ниже 420dp; это лечит ровно «S\nt\na\nt» с вашего скриншота

Осталось:
- `app_shell.dart:42` — `_AppShellState with WindowListener`: mixin из **desktop-only** плагина `window_manager` вшит в тип мобильной оболочки
- `app_shell.dart:334` — нет `SafeArea` в мобильной ветке → статус-бар Android перекрывает `_QuickStatusBar` (это второй симптом со скриншота)
- 6 незащищённых `Process.run/start` с windows-командами (`explorer`, `rundll32`, `powershell`), в т.ч. `AutostartService.setEnabled()` из `settings_screen.dart:1388` → `Process.runSync('reg', …)` на Android
- `daemon_launcher.dart:28` — хардкод `C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe`
- 6 breakpoint-констант (420/480/600/720/900) без единого источника истины; 16 экранов с `EdgeInsets.all(24)`
- Нет ни одного теста на ширине телефона — именно поэтому баги дошли до релиза

### 1.6 CI, который ничего не проверяет ⚠️ SUBAGENT (+ моя проверка)

Что реально проверено субагентом прогоном: `go vet ./...` чисто, `go test -count=1 ./...` — все 11 пакетов PASS, `go test -race` — 0 гонок. Это хорошая база.

Дыры:
- `flutter analyze` / `flutter test` / сборки Android и Linux в CI **отсутствуют** → сломанный мобильный layout проходит зелёным
- `release.yml` содержит один job `windows-installer` → Linux и Android собираются вручную с ноутбука
- `release.yml` качает sing-box **без проверки хэша** — supply-chain риск
- 7 Go-пакетов вообще без тестов
- Версия расползлась по 4 файлам: daemon `0.1.0-dev`, Tauri `0.1.0`, Flutter `0.3.0`, NSIS `0.5.0`

### 1.7 Прочее по боту ⚠️ SUBAGENT

- 6 из 11 вызовов `requests` без `timeout` ✅ VERIFIED (11 всего, 5 с таймаутом) → поток поллинга может зависнуть навсегда
- `promo_apply` rate-limit определён, но **нигде не вызывается** → промокоды не лимитируются
- `/broadcast` и `/buy` без rate-limit
- Хардкод пароля PostgreSQL `postgres` (строка 2546)
- WAL не включён в SQLite при 5 демон-потоках → риск `database is locked`
- Токен сессии передаётся в query-string URL (попадает в логи nginx)
- CORS wildcard `*` на `/stats-api`

Хорошее: секреты через env с валидацией на старте, `secrets.token_urlsafe(32)` для сессий, link-коды атомарны (`WHERE used_at IS NULL`), инъекций в остальных 100+ запросах нет.

### 1.8 Go-демон: локальный API ⚠️ SUBAGENT

- `internal/api/server.go:1219` — при сбое `crypto/rand` токен = `fallback-<UnixNano>` ✅ VERIFIED, предсказуем
- Широкий CORS: эхо любого `Origin` → любая веб-страница на машине может дёргать локальный API демона
- `AllowLAN=true` по умолчанию → SOCKS слушает `0.0.0.0`
- Нет ротации логов sing-box

---

## P2 — Следующая неделя

- **Распилить `bot.py`** (3584 строки, 105 функций в одном модуле): `db.py`, `remnawave.py`, `payments.py`, `support.py`, `referral.py`, `web.py`, `handlers/`. По модулю за коммит, тесты уже есть.
- **Наблюдаемость:** healthcheck бота, работающий алерт в Telegram (см. 1.1 — сейчас алертов нет), cron-сторож диска, мониторинг подписочной ссылки.
- **Обновить образы** ⚠️ SUBAGENT: `nginx:1.24` (3 года), `remnawave/backend:2` (4 месяца).
- **Чистка репозитория:** в корне ~60 случайных `.wav`, `.mp4`, `.png`, `.py` от видео-экспериментов вперемешку с продуктовым кодом.

## P3 — Потом

- Уведомления об истечении подписки за 3/1 день (удержание дешевле привлечения).
- E2E-тест полного пути: бот → оплата → выдача ключа → коннект клиента.
- iOS ⚠️ SUBAGENT: Network Extension entitlement, Apple Developer $99/год, gomobile под iOS, 4–8 недель. macOS: 2–4 недели. Каталогов `ios/` и `macos/` нет. Обсуждать после того, как Android заработает.

---

## Порядок работ

```
День 1  0.1 диск → 0.2 бэкап → 0.5 записка с оферты → 0.6 идемпотентность   [~4 ч]
День 2  0.3 kill switch (решение A или B) → 0.4 Android (A) → 1.1 алерты
День 3  1.3 firewall/порты/certbot-hook/headers на VPS
День 4  1.5 Flutter UX + 1.4 мобильный сайт (гамбургер + overflow таблиц)
День 5  1.6 CI: flutter test/analyze + android + linux jobs, единая версия
Спринт  0.4B Android VpnService (3–5 дней)
Далее   Lava live provider (без него монетизация не работает), 2.x
```

## Решения, которые нужны от вас

1. **Kill Switch** — убрать из UI сейчас (A) или подключать по-настоящему (B)?
2. **Android APK** — снять с сайта сейчас или оставить нерабочий?
3. **DePIN-фарм на боевом VPS** — переносить на отдельную машину?
4. **`/opt/flutter` (1.8 ГБ) на VPS** — удалять? Нужен ли он там вообще?
5. **Lava** — статус заявки? Без реализации live-провайдера юридические страницы ни к чему не ведут.
6. **Диск 24 ГБ** — расширять тариф или держаться на чистке?
