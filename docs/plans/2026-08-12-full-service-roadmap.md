# MosaicVPN — полный план доработок сервиса

> Составлен 2026-08-12 после аудита живой инфраструктуры (VPS, бот, сайт, клиенты).
> Всё, что помечено ✅ verified — подтверждено реальным выводом команд, а не памятью.

**Цель:** довести MosaicVPN из состояния «работает у автора» до состояния «продаётся незнакомцам»: устойчивый VPS, тонкий бот, конвертящий сайт, и клиенты, которые реально туннелируют трафик на всех заявленных платформах.

**Стек:** Go 1.25 daemon (`mosaicd`) + Flutter 3.44 GUI (`MosaicBox`) + Python/telebot бот + Remnawave (Docker) + nginx (Docker) + sing-box.

---

## 0. Что показал аудит (базовая линия)

| Область | Состояние | Доказательство |
|---|---|---|
| VPS диск | **88% занято** (21G/24G, 3.0G свободно) | `df -h /` ✅ |
| journald | **2.3 ГБ**, лимиты не заданы (`journald.conf` пустой) | `du -sh /var/log/journal`, `grep -vE '^#|^$'` ✅ |
| syslog | `syslog.1` = 193M, `syslog` = 58M, ротация слабая | `du -sh /var/log/*` ✅ |
| Docker | 6 контейнеров Up, remnawave healthy, 2.9G образов | `docker ps` ✅ |
| Бэкапы БД | Есть, ежечасно, 30 дней, 15M — **только локально** | `/opt/remnawave/backups`, `backup-db.sh` ✅ |
| Бот | `mosaic-bot.service` active, **3584 строк в одном файле** | `systemctl is-active`, `wc -l` ✅ |
| Платежи в боте | Только CryptoPay; Lava живёт в Go-демоне | `grep -inE 'lava\|yookassa\|cryptopay'` ✅ |
| Сайт | 9 статических страниц, **1–3 @media на файл** | `grep -c '@media' site/*.html` ✅ |
| iOS / macOS | **Каталогов `ios/`, `macos/` не существует** | `ls flutter/ios` → нет ✅ |
| Android туннель | **VpnService отсутствует**, прав только INTERNET/NETWORK_STATE/FOREGROUND_SERVICE/POST_NOTIFICATIONS | `grep VpnService android/app/src/main/` → пусто ✅ |
| Android архитектура | 5 файлов используют `Process.start` / `Process.run` — на Android невозможно | `grep -rln 'Process.run\|Process.start' lib/` ✅ |
| Хардкод путей | `C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe` в проде | `daemon_launcher.dart:29` ✅ |
| Адаптивность | 15 экранов с жёстким `EdgeInsets.all(24)` | `grep -c 'EdgeInsets.all(24)'` ✅ |
| CI | Только Go-тесты + Windows cross-build + ui lint. **Нет** flutter test, нет Android/Linux сборки | `.github/workflows/ci.yml` ✅ |
| Release CI | Один job `windows-installer` | `.github/workflows/release.yml` ✅ |
| Тесты | 22 Go-теста, 8 Flutter-тестов | `ls internal/*/*_test.go` ✅ |

**Главный вывод:** самая честная проблема не в UI. **Android APK, который выложен в релиз v0.3.0 и на который ссылается сайт, физически не может поднять VPN** — в манифесте нет `VpnService`, а клиент рассчитывает запускать локальный Go-процесс, чего Android не позволяет. Приложение открывается, рисует дашборд и не туннелирует ничего. Это блокер релиза, а не косметика.

---

## Приоритеты

- **P0 — сегодня/завтра.** Падение или обман пользователя. VPS диск, Android-туннель либо снятие APK с сайта.
- **P1 — эта неделя.** Мобильный UX, адаптивность, деньги, CI.
- **P2 — следующая.** iOS/macOS, рефакторинг бота, наблюдаемость.
- **P3 — потом.** Рост, автоматизация, полировка.

---

# P0 — Блокеры

## Задача 0.1 — Освободить диск VPS и ограничить логи навсегда

**Проблема:** 3.0 ГБ свободно из 24. Postgres при заполнении диска встанет, Remnawave умрёт вместе со всеми подписками.

**Файлы:** `/etc/systemd/journald.conf`, `/etc/logrotate.d/rsyslog` (на VPS).

Шаг 1 — посмотреть, что съедено:
```bash
ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152 \
  'du -sh /var/log/* | sort -rh | head; df -h /'
```
Ожидаемо: `journal` ~2.3G, `syslog.1` 193M, диск 88%.

Шаг 2 — обрезать журнал до 300 МБ:
```bash
ssh ... 'journalctl --vacuum-size=300M'
```
Ожидаемо: `Vacuuming done, freed ~2.0G`.

Шаг 3 — зафиксировать лимит, чтобы не вернулось:
```bash
ssh ... 'printf "SystemMaxUse=300M\nSystemMaxFileSize=50M\nMaxRetentionSec=14day\n" \
  >> /etc/systemd/journald.conf && systemctl restart systemd-journald'
```

Шаг 4 — ужать rsyslog:
```bash
ssh ... 'sed -i "s/^\trotate [0-9]*/\trotate 3/" /etc/logrotate.d/rsyslog && logrotate -f /etc/logrotate.d/rsyslog'
```

Шаг 5 — почистить Docker:
```bash
ssh ... 'docker image prune -af --filter "until=168h"; docker system df'
```

Шаг 6 — проверить: `df -h /` → занято **≤ 70%**. Если нет — искать дальше `du -x -d1 / | sort -rh`.

Шаг 7 — сторож, чтобы это не повторилось: cron-джоб, который молчит при норме и пишет только при >85%.

---

## Задача 0.2 — Оффсайт-бэкап БД

**Проблема:** бэкапы лежат на том же диске, который на 88% полон. Умрёт VPS — умрут все платящие подписки.

Шаг 1 — на локальной машине проверить, что тянется:
```bash
scp -i ~/.ssh/id_ed25519_vitaly \
  root@5.175.188.152:/opt/remnawave/backups/$(ssh ... 'ls -t /opt/remnawave/backups | head -1') \
  /c/Users/ANEN/mosaicvpn/backups/
```
Шаг 2 — оформить как ежедневный cron на **локальной** машине (не на VPS: смысл в том, чтобы копия жила вне VPS).
Шаг 3 — проверить восстановимость: `pg_restore --list <dump> | head` должен показать таблицы, а не ошибку.

Не делать: заливку дампов в сторонние облака без явного разрешения владельца — там персональные данные пользователей.

---

## Задача 0.3 — Android: решить судьбу APK (развилка, нужно решение владельца)

**Факт:** в `flutter/android/app/src/main/AndroidManifest.xml` нет `<service android:name=".MosaicVpnService">`, нет `BIND_VPN_SERVICE`. `daemon_launcher.dart` вызывает `Process.start('mosaicd')` — на Android это `ProcessException`. Значит APK не туннелирует.

### Вариант A — честно снять APK со страницы (30 минут, P0)
Быстро закрывает обман пользователя, пока делается вариант B.

1. `site/index.html` — заменить кнопку скачивания Android на «Android — в разработке», убрать ссылку на `.apk`.
2. GitHub Release v0.3.0 — пометить APK как `pre-release / not functional` в описании.
3. Деплой: `scp site/index.html root@...:/etc/letsencrypt/landing/index.html`, проверить `curl -I` → 200.

### Вариант B — сделать Android по-настоящему (3–5 дней, P1)
Это не «дописать пару строк», это отдельная архитектура: на Android нет отдельного процесса-демона, ядро sing-box должно жить **внутри** приложения как библиотека под `VpnService`.

1. Добавить `libcore` (sing-box, скомпилированный через `gomobile bind` в `.aar`) в `android/app/libs/`.
2. Написать `MosaicVpnService.kt`: наследник `VpnService`, поднимает `TUN` через `Builder`, отдаёт fd в libcore.
3. `AndroidManifest.xml`: `<service android:permission="android.permission.BIND_VPN_SERVICE">` + `intent-filter android.net.VpnService` + `FOREGROUND_SERVICE_TYPE`.
4. MethodChannel `ru.mosaicvpn/tunnel` с методами `connect(config)`, `disconnect()`, `status()`.
5. В Dart сделать `DaemonApi` абстракцией с двумя реализациями: `HttpDaemonApi` (desktop, как сейчас) и `ChannelDaemonApi` (Android). Точка выбора — `AppPlatform.isMobile`, который уже есть в `core/platform/app_platform.dart`.
6. Обязательно: запрос разрешения `VpnService.prepare()` при первом коннекте, foreground-нотификация (Android убьёт сервис без неё).

**Рекомендация:** сделать A сегодня, B — как отдельный спринт. Продавать нерабочий клиент хуже, чем не иметь его.

---

# P1 — Эта неделя

## Задача 1.1 — Адаптивность Flutter (частично начата)

**Уже сделано в рабочей копии (не закоммичено):**
- `app_shell.dart`: breakpoint переведён с `size.width > 900` на `size.shortestSide > 600` — телефон в лендскейпе больше не получает десктопный сайдбар.
- `atlas_widgets.dart` `SectionHeader`: при ширине < 420dp заголовок и кнопка складываются в колонку. Это лечит ровно тот баг со скриншота, где «Stations» и «Sources» рассыпались по одной букве в строку.

**Осталось:**

1. **Responsive padding.** 15 экранов с `EdgeInsets.all(24)`. Ввести в `atlas_theme.dart`:
   ```dart
   static EdgeInsets screenPadding(BuildContext ctx) {
     final w = MediaQuery.of(ctx).size.width;
     return EdgeInsets.all(w < 480 ? 12 : w < 900 ? 16 : 24);
   }
   ```
   и заменить во всех 15 файлах. Проверка: `grep -c 'EdgeInsets.all(24)' flutter/lib/features/*/*.dart` → 0.

2. **SafeArea.** На скриншоте статус-бар Android наезжает на `_QuickStatusBar` («Disconnected / Kill Switch / QuickConnect» слиплись с системными иконками). Обернуть `Scaffold.body` в `SafeArea(top: true)` для мобильной ветки.

3. **`_ConnectionPanel`.** «DI/SC/O/N/NE/CT/ED» вертикальной лапшой — панель получила ~120dp. Задать `minWidth` через `ConstrainedBox` и `FittedBox(fit: BoxFit.scaleDown)` для крупного статуса.

4. **`_QuickStatusBar` height: 48** — фиксированная высота при текстовом масштабе 1.3+ обрежет контент. Заменить на `minHeight`.

5. **Widget-тесты на узкий экран.** `flutter/test/features/responsive_test.dart`: прогнать `AppShell`, `ServersScreen`, `DashboardScreen` в `tester.view.physicalSize = Size(360*3, 800*3)` и утверждать отсутствие overflow (`expect(tester.takeException(), isNull)`).

## Задача 1.2 — Убрать хардкод пути

`daemon_launcher.dart:29` содержит `C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe`. У любого другого пользователя это мёртвая ветка. Убрать строку, оставить `appDir`, `Program Files`, `%LOCALAPPDATA%\MosaicVPN`.

## Задача 1.3 — CI, который реально что-то проверяет

Сейчас CI не собирает ни Android, ни Linux и не гоняет flutter-тесты. То есть сломанный мобильный layout проходит зелёным.

В `.github/workflows/ci.yml` добавить job:
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
В `release.yml` добавить jobs `linux-bundle` и `android-apk`, чтобы релизы перестали собираться вручную с ноутбука.

## Задача 1.4 — Деньги: свести платежи в одно место

Сейчас CryptoPay живёт в `bot/bot.py`, Lava — в `internal/billing/lava.go`, YooKassa упомянут в `PROJECT_STATUS.md`. Три разных места, разные состояния.

1. Определить один источник истины по платежам (предлагаю Go-демон + REST, бот дергает его).
2. Довести модерацию Lava до конца: страницы `offer.html`, `refund.html`, `delivery.html`, `terms.html`, `contacts.html` уже переписаны — нужен статус заявки. **Реквизиты (ИНН, адрес, телефон) не выдумывать, брать только у владельца.**
3. Идемпотентность вебхуков: тест, что двойной POST одного `invoice_id` не продлевает подписку дважды.

## Задача 1.5 — Сайт: мобильная вёрстка и конверсия

`index.html` — 3 медиа-запроса на весь лендинг, у остальных страниц по одному. Проверить в 360dp:
```bash
# локально
python -m http.server 8099 --directory site
```
и прогнать через browser tool на 360×800. Что почти наверняка сломано: таблица тарифов, шапка, кнопки скачивания в ряд.

Дополнительно: `docs.html` должен объяснять, какая платформа что умеет — **без обещаний iOS, пока его нет**.

---

# P2 — Следующая неделя

## Задача 2.1 — iOS и macOS: перестать их обещать
Каталогов не существует. Пока не заведены — убрать «5 платформ» из маркетинга. iOS дороже Android: нужен Apple Developer ($99/год), Network Extension entitlement, и App Store почти наверняка потребует юрлицо для VPN-категории. Это отдельное решение владельца, не техническая задача.

macOS дешевле (нет ревью, если раздавать вне Store): `flutter create --platforms=macos .` + подпись + notarization.

## Задача 2.2 — Распилить `bot.py`
3584 строки, 100+ функций в одном модуле: БД, API Remnawave, платежи, тикеты, рейтинги, промокоды, рассылки, вебхуки. Любая правка рискует всем.

Порядок (по одному модулю за коммит, тесты не ломать — они уже есть: `test_web_cabinet.py`, `test_link_codes.py`, `test_link_endpoint.py`):
```
bot/db.py          — init_db, get_user, save_user, invoices
bot/remnawave.py   — api_get_user, api_create_user, api_extend_user
bot/payments.py    — cryptopay, invoice polling
bot/support.py     — tickets, ratings, complaints
bot/referral.py    — ref_stats, leaderboard, promo
bot/web.py         — /api/session, /api/billing/*
bot/handlers/      — telebot handlers
bot/bot.py         — только сборка и запуск
```

## Задача 2.3 — Наблюдаемость
Сейчас единственный способ узнать о падении — заметить самому. Нужны: healthcheck-эндпоинт бота, алерт в Telegram при недоступности Remnawave API дольше 2 минут, cron-сторож диска (из 0.1) и uptime подписочной ссылки.

---

# P3 — Потом

- Уведомления об истечении подписки за 3/1 день (удержание дешевле привлечения).
- Автотест полного пути: бот → оплата → выдача ключа → клиент коннектится.
- Windows-инсталлятор с автообновлением (NSIS уже есть в `installer/`).
- Чистка корня репозитория: там ~60 случайных `.wav`, `.mp4`, `.png`, `.py` от видео-экспериментов, вперемешку с кодом продукта.

---

## Порядок выполнения

```
День 1   0.1 диск → 0.2 бэкап → 0.3A снять APK с сайта     [P0, ~3 часа]
День 2   1.1 адаптивность + 1.2 хардкод + widget-тесты      [P1]
День 3   1.3 CI (flutter test + android + linux)            [P1]
День 4   1.4 платежи, 1.5 мобильный сайт                    [P1]
Далее    0.3B Android VpnService — отдельный спринт 3-5 дней
Потом    2.x бот, наблюдаемость, iOS-решение
```

## Открытые вопросы к владельцу

1. **Android:** снимаем APK с сайта сейчас (вариант A) и делаем нормально потом, или оставляем как есть?
2. **iOS:** платим $99/год и заводим юрлицо, или убираем из обещаний?
3. **Lava:** какой статус заявки на модерацию? Реквизиты нужны от вас, выдумывать не буду.
4. **VPS:** 24 ГБ диска для Remnawave + логов + бэкапов тесно. Расширять или продолжать подчищать?
