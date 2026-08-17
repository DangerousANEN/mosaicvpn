# MosaicVPN — полный технический handoff и контекст проекта

**Дата документа:** 17 августа 2026 года  
**Назначение:** передача контекста следующему разработчику или AI-агенту без необходимости повторно изучать всю историю проекта.  
**Репозиторий:** [DangerousANEN/mosaicvpn](https://github.com/DangerousANEN/mosaicvpn)  
**Публичный сайт:** [https://sub.zxc1x1.ru](https://sub.zxc1x1.ru)  
**Telegram-бот:** [@mosaicvpnbot](https://t.me/mosaicvpnbot)

> Этот документ намеренно не содержит Telegram Bot Token, платёжные секреты, Remnawave/API tokens, SSH private keys, пароли, signing keys и другие credentials. Секреты должны храниться только в защищённых environment-файлах и secret stores.

---

## 1. Executive summary

MosaicVPN — экосистема сервиса сетевой защиты с общим личным кабинетом, Telegram-ботом, веб-сайтом и кроссплатформенным клиентом. Пользователь должен иметь единый аккаунт и одинаковый доступ к подписке, балансу, заморозке, оплате, устройствам и маршрутам независимо от того, вошёл ли он через Telegram, сайт или приложение.

Основная пользовательская модель — **«Подписка → Маршрут»**. Пользователь выбирает подписку, затем выбирает маршрут. Маршрутом может быть одиночный сервер конкретного протокола или серверная Smart Group. Smart Group не является заранее зашитой в UI категорией с фиксированным названием. Сервер передаёт manifest с названием, описанием, типом, политикой выбора, пулом и ограничениями, а универсальный клиент только отображает и исполняет эту метаинформацию.

Ключевая архитектурная цель — не использовать схему `клиент → VPS MosaicVPN → узел пула`. Пользовательский трафик должен идти напрямую через выбранный клиентом узел пула. VPS MosaicVPN предоставляет API, manifest, шард кандидатов, admission-фильтрацию и минимальную серверную проверку, но не является транзитным прокси для пользовательского трафика.

---

## 2. Бизнес-модель и ожидания владельца

Сервис тарифицируется посуточно. Базовая модель — **1 ₽ за 1 день**. Пользователь может пополнять баланс на фиксированный или произвольный срок, после чего средства списываются посуточно. Требовались пресеты 10 и 30 дней, а также свободное пополнение с пользовательским количеством дней. Бесплатный trial выдаётся через Telegram-бота после выполнения обязательных условий, включая подписку на необходимые Telegram-каналы. Список обязательных каналов должен управляться администратором через веб-панель.

Подписку можно заморозить и разморозить из Telegram-бота, сайта и клиента. Доступ и баланс должны быть синхронными во всех трёх точках входа. Пользователю также требуется возможность пересоздать subscription link, если ссылка была раскрыта и начала использоваться посторонними.

Администратор должен иметь веб-инструменты для просмотра пользователей, начисления баланса и дней, управления обязательными Telegram-каналами, рассылок, уведомлений о технических работах, изменения цены, скидок, начисления бонусов и просмотра статистики. В боте должны быть аккуратные сообщения, единый формальный стиль обращения на «вы», понятная типографика без старого Markdown-форматирования со звёздочками и без спорных формулировок, которые могут вызвать вопросы у платёжного провайдера.

Платёжный стек предусматривает интеграцию Lava.ru по СБП и картам РФ. На сайте и в боте должны быть единые тарифы, статусы оплаты, success/fail callbacks, idempotency и понятная обработка ситуации, когда платёжный метод ещё находится на подключении.

---

## 3. Репозиторий и структура исходников

Основной GitHub repository — `DangerousANEN/mosaicvpn`. В нём находятся backend daemon, Flutter client, Telegram bot, static website, tests и documentation.

| Путь | Назначение |
|---|---|
| `cmd/mosaicd/` | Точка входа Go daemon `mosaicd`. |
| `cmd/mosaic/` | Go CLI-клиент daemon API. |
| `internal/api/` | Локальный HTTP API daemon, bearer auth, manifest, subscription, connect, probe и billing-related handlers. |
| `internal/proto/` | Канонические модели API, manifest, groups, policies, probes, status и speed results. |
| `internal/state/` | State manager, backend interface и реальный sing-box backend. |
| `internal/subs/` | Парсинг subscription formats, manifest construction, group resolution и pool-facing logic. |
| `internal/pool/` | Общий pool, admission filtering, health/pruning и кандидатная выдача. |
| `internal/store/` | Persisted JSON state, preferences, subscriptions, servers, rules и cache. |
| `internal/single/` | Single-instance enforcement. |
| `internal/paths/` | Cross-platform data directory resolution. |
| `flutter/` | Активный кроссплатформенный Flutter client. |
| `flutter/lib/core/api/` | Daemon API client, recovery, mocks и provider forwarding. |
| `flutter/lib/core/models/` | Dart models, включая manifest и Smart Group quality models. |
| `flutter/lib/core/services/smart_group_selector.dart` | Local Smart Group probing, ranking, cache и failover. |
| `flutter/lib/features/dashboard/` | Основной экран «Подписка → Маршрут». |
| `flutter/android/`, `flutter/linux/`, `flutter/windows/` | Platform-specific Flutter integration. |
| `bot/bot.py` | Telegram bot, web cabinet API, billing callbacks, account and subscription management. |
| `site/` | Static landing, cabinet, legal pages, provider docs and download section. |
| `docs/` | Architecture, plans, handoff documents and speed probe contract. |
| `mosaicvpn_smart_groups_deck/` | Presentation project describing Smart Groups architecture. |

В README исторически описана параллельная Tauri/React архитектура (`ui/`, `mosaic-ui`). Для текущего активного клиентского направления главным является `flutter/`. Перед дальнейшей работой необходимо не смешивать legacy Tauri paths с Flutter runtime без отдельного решения по миграции.

---

## 4. Клиентская архитектура

Flutter-клиент является универсальным приложением для MosaicVPN и потенциально для других VPN-провайдеров. Клиент не должен содержать hardcoded Mosaic-only group IDs, например `minimum-ping`, `germany` или `free-lte`. Он знает только generic route types и умеет отображать server-provided metadata.

Для неопытного пользователя главный экран — dashboard подключения. На нём должна быть одна ясная последовательность: выбор подписки, затем выбор группы или одиночного сервера, затем режим `tun` или `proxy`, затем кнопка подключения. Не должно быть двух конкурирующих способов выбора маршрута.

Для продвинутого пользователя должны быть доступны расширенные настройки, egresses, протоколы, proxy listeners, DNS, routing rules, локальные группы и ручной импорт. При этом базовый сценарий не должен требовать перехода по сложным вкладкам.

Требования к desktop UX включают тёмную тему, английский и русский языки, язык системы по умолчанию, корректную локализацию, аккуратные scrollbars, tray menu в стиле Mosaic, single instance, автосворачивание в tray по умолчанию, настройку поведения при закрытии, полное завершение `mosaicd` и `sing-box` из tray, portable data directory внутри portable installation folder и отсутствие тестовых admin subscriptions.

Android-клиент должен использовать native VPN runtime, корректно запрашивать VPN permission, поддерживать тот же account/subscription flow, не показывать mock data и использовать ту же manifest-driven route model. Иконка, application name и adaptive icon должны быть собственными MosaicVPN, а не дефолтными Flutter.

---

## 5. Daemon и локальная коммуникация

`mosaicd` — локальный daemon, который запускает и контролирует sing-box. Daemon слушает только loopback-адрес на динамическом порту. При старте создаётся lockfile с endpoint, bearer token, PID, version и временем запуска. Flutter-клиент читает lockfile и восстанавливает endpoint, если старый порт больше не работает.

Все запросы к daemon требуют `Authorization: Bearer <token>`. Endpoint не должен быть доступен из сети. Клиент использует retry/recovery для `connection refused`, перечитывает lockfile и повторяет запрос безопасное ограниченное число раз.

Основные API-группы:

| Endpoint family | Назначение |
|---|---|
| `/v1/status` | Текущее состояние daemon, connection, proxy listeners и version. |
| `/v1/connect`, `/v1/disconnect` | Подключение к одиночному серверу или разрешённому group candidate. |
| `/v1/subscriptions` | Получение, добавление, refresh, reorder, rename и удаление subscriptions. |
| `/v1/servers` | Локальные imported profiles и single servers; pool nodes не должны показываться пользователю напрямую. |
| `/v1/manifest` | Provider-defined groups, policies, metadata и account/provider data. |
| `/v1/groups/{id}/candidates` | Opaque candidate shard для локального ranking. |
| `/v1/groups/{id}/probe` | Server-validated candidate membership и lightweight transport probe. |
| `/v1/test/url`, `/v1/test/ip` | Проверки через active tunnel. |
| `/v1/test/speed` | Bounded HTTPS download/upload probe через active local tunnel. |
| `/v1/prefs` | Preferences, theme, language, mode, close-to-tray и network settings. |
| `/v1/rules` | Routing rules. |
| `/v1/events` | Server-Sent Events для status/event updates. |
| `/v1/diag` | Диагностический dump. |

При нормальном shutdown клиент должен disconnect, остановить sing-box, закрыть daemon и освободить single-instance lock. При закрытии окна с настройкой «сворачивать в трей» процессы продолжают работать; при полном выходе они завершаются.

---

## 6. Smart Group manifest-driven architecture

Smart Group — это виртуальный route entry, который ссылается на пул допустимых узлов. Пользователь видит Smart Group в общей таблице маршрутов наравне с VLESS, Hysteria2, Shadowsocks и другими протоколами. В колонке Type отображается generic label `Smart Group` / `Группа`, а конкретная стратегия `urltest`, `fallback` или `weighted_round_robin` не должна становиться пользовательским protocol label.

Пример структуры manifest:

```json
{
  "id": "provider-defined-group-id",
  "title": "Минимальный пинг",
  "route_type": "smart_group",
  "type": "weighted_round_robin",
  "pool_id": "provider-private-pool",
  "description": "Автоматически выбирает лучший доступный маршрут.",
  "category": "smart",
  "disabled": false,
  "client_policy": {
    "mode": "weighted",
    "shard_size": 16,
    "max_parallel_probes": 4,
    "probe_ttl_seconds": 600,
    "max_failover_tries": 3,
    "latency_weight": 0.45,
    "loss_weight": 0.30,
    "stability_weight": 0.25,
    "speed_weight": 0,
    "speed_probe": {
      "enabled": false,
      "download_urls": [],
      "upload_url": "",
      "sample_bytes": 2097152,
      "timeout_seconds": 12,
      "max_candidates": 2,
      "target_mbps": 50
    }
  }
}
```

Клиент получает opaque candidate IDs, но не получает пул целиком и не должен показывать pool nodes в UI. Для каждого кандидата клиент выполняет локальные transport-aware probes, рассчитывает loss, median latency, p95 latency и jitter, затем локально сортирует кандидатов. VPS выполняет только admission filtering: удаляет недоступные/мусорные узлы и не проводит дорогой полный quality ranking для каждого пользователя.

При подключении клиент может выполнить bounded failover: попробовать несколько лучших кандидатов в порядке локального score. Если активный узел перестаёт работать, клиент должен бесшовно переключиться на следующий допустимый candidate без раскрытия пользователю внутреннего pool.

---

## 7. HTTPS speed probe

Ookla использовать нельзя: сервис блокируется или нестабилен в целевых сетях, включая Россию. Вместо этого введён provider-configurable `SpeedProbePolicy` и endpoint `POST /v1/test/speed`.

Поддерживаются bounded HTTPS download и upload. Endpoint URLs должны быть HTTPS. Download ограничен диапазоном от 256 KiB до 8 MiB, default — 2 MiB. Timeout ограничен 3–30 секундами, default — 12 сек. Для ranking проверяется не более 3 кандидатов, default — 2. Upload отправляется как bounded `application/octet-stream` POST.

Speed probe выполняется через active local sing-box SOCKS outbound. Пользовательский трафик и probe traffic не идут транзитом через MosaicVPN VPS. Сначала клиент выполняет дешёвый transport ranking, затем для speed-enabled groups последовательно подключает только лучших кандидатов, измеряет скорость и пересортировывает их локально. Результаты download/upload Mbps сохраняются в локальном quality cache с TTL.

Полный контракт находится в [`docs/speed-probes.md`](./speed-probes.md).

---

## 8. Pool, node admission и Free LTE placeholder

Общий pool содержит узлы, которые пользователи не видят напрямую. Collector должен собирать узлы из разрешённых крупных источников, нормализовать formats, дедуплицировать, проверять минимальную доступность и удалять мёртвые узлы. VPS admission loop должен быть лёгким: TCP/handshake/HTTP liveness checks, ограниченная concurrency, backoff, TTL и удаление повторно мёртвых узлов.

Пользовательский клиент получает только shard кандидатов для конкретной Smart Group. Качество по текущей сети пользователя измеряется только на устройстве пользователя.

Категория **«Свободный LTE» / `reserved-lte-compat`** оставлена как disabled placeholder. У неё нет активного feed discovery, нет логики поиска узлов для обхода whitelist и нет скрытой реализации. Включать её можно только после отдельного owner-authorized и compliance-reviewed источника профилей.

---

## 9. Подписки и локальные коллекции

Поддерживаются remote subscriptions и local collections. Пользователь может создать локальную collection, добавить профиль из clipboard, файла, QR или вручную. Clipboard input должен определять, является ли содержимое subscription, одиночным server link или набором profiles, после чего предлагать создать новую local collection или добавить профили в существующую.

Ожидаемые протоколы: VLESS с TLS/Reality, WebSocket, gRPC и xHTTP; Hysteria2, Shadowsocks, частично Trojan и VMess. На roadmap остаются полноценная Naive и AmneziaWG support. Pool servers не должны попадать в пользовательский raw server list.

Remote subscriptions должны поддерживать reorder drag-and-drop, стрелочную навигацию, rename/delete/context menu и сохранение порядка в backend. Portable builds должны хранить состояние в собственной portable directory, а не в обычном user profile path.

---

## 10. Telegram bot

Bot source находится в `bot/bot.py`. На VPS исторически используется systemd service `mosaic-bot`, отдельная virtualenv и SQLite database. Боевые secrets должны храниться в защищённом env-файле, а не в git.

Основные bot функции: регистрация, Telegram link/pairing, профиль, баланс, trial, обязательные channel subscriptions, тарифы, пополнение, freeze/unfreeze, subscription link, пересоздание link, support, language, broadcast и admin operations.

Критические требования к боту: единый формальный стиль на «вы», отсутствие странных звёздочек и старого форматирования, корректное отображение профиля, отсутствие рекламных формулировок про обход блокировок, единые тексты с сайтом и клиентом, idempotent payment callbacks, защита от двойного начисления и безопасная валидация admin actions.

Существующие тесты бота находятся в `bot/test_*.py`. Перед production deploy необходимо запускать syntax check и весь набор bot tests, затем отдельно проверять systemd status и последние journal logs.

---

## 11. Website и web cabinet

Static site находится в `site/` и включает `index.html`, `cabinet.html`, `docs.html`, `offer.html`, `terms.html`, `privacy.html`, `delivery.html`, `refund.html` и `contacts.html`. Публичный домен — `https://sub.zxc1x1.ru`.

Сайт должен объяснять service model без спорных формулировок, показывать тарифы, 3-day trial, до 5 устройств, freeze, account access, documentation for providers и download cards. На mobile должна быть доступна кнопка кабинета, текст таблиц не должен обрезаться, а кнопки разных downloads не должны сливаться.

Cabinet должен поддерживать общий account flow: login/pairing, user ID, balance, subscription status, freeze/unfreeze, payments, link regeneration, admin entry for authorized owner и отображение актуального client version.

Provider documentation должна описывать manifest, group metadata, route types, candidate shards, client policies, direct routing, pool privacy и integration contract без раскрытия внутренних pool nodes.

---

## 12. Payment integrations

Lava.ru integrations должны разделяться для сайта и Telegram-бота. Для каждого магазина необходимы собственные project ID, secret key, additional verification key, success webhook, failed webhook, return URLs и idempotency storage. Secrets не должны попадать в frontend, GitHub, handoff documents или public logs.

Пользователю не должно требоваться регистрироваться в Lava.ru: он оплачивает в MosaicVPN checkout. Если provider payment method ещё подключается, сайт и бот показывают понятную disabled placeholder кнопку, не маскируя её под рабочую оплату.

Тарифный flow должен поддерживать 10 дней, 30 дней и пользовательское число дней в заданном диапазоне. Цена, скидка и начисление должны рассчитываться на сервере, а не доверять клиенту.

---

## 13. VPS and deployment map

Историческая deployment map проекта выглядит следующим образом:

| Service | Location / runtime |
|---|---|
| Telegram bot | `/opt/mosaic-bot/`, systemd unit `mosaic-bot.service`, SQLite database inside service directory, protected env file under `/etc/`. |
| Remnawave | `/opt/remnawave/`, Docker services for nginx, panel, PostgreSQL, Redis, subscription page and node runtime. |
| Landing/cabinet static files | `/etc/letsencrypt/landing/` behind nginx for `sub.zxc1x1.ru`. |
| Bot HTTP API | Internal service port historically `12223`; nginx routes `/api/` and `/stats-api/` to it. |
| Mosaic daemon | Runs on the user device, not as the public VPS transit proxy. |
| Public GitHub source | `https://github.com/DangerousANEN/mosaicvpn`. |

Exact VPS IP, SSH key path, access usernames and production credentials are intentionally omitted from this document. They must be retrieved from the owner’s secure operations environment. Never place them in GitHub or public site files.

---

## 14. Current validation and release status

The current Flutter source was validated with Flutter stable 3.47.0 and Dart 3.13.0. `flutter analyze` passes without issues and the Flutter test suite passes. The Go backend passes `go test ./...`.

A Linux x64 release bundle was built and packaged. Android release APK and AAB were built and checksummed using a temporary local validation keystore. These Android files prove that the packaging pipeline works, but they are not signed with the production owner key and must not be presented as the final store release.

Windows release build was not executed because Flutter Windows desktop builds require a Windows host with the Windows desktop toolchain. Existing GitHub assets under the historical `v0.3.11` release are older release artifacts and must not automatically be relabeled as the new Smart Group/speed-probe build.

Release gates still required before calling the ecosystem production-ready:

| Gate | Required result |
|---|---|
| Windows | Build installer and portable package on Windows; verify single instance, tray, shutdown, data paths and connection. |
| Linux | Run bundle on a real Linux desktop and verify daemon/sing-box lifecycle and proxy/TUN behavior. |
| Android | Install APK on a real Android device, grant VPN permission, connect through native VPN runtime and test account/subscriptions. |
| Signing | Replace validation keystore with protected production Android signing key and Windows code-signing certificate. |
| Backend | Run daemon API tests and real direct-route connect against authorized test nodes. |
| Payment | Run Lava sandbox/production callback tests with idempotency and refund paths. |
| Website | Validate every public download link and mobile cabinet flow after deployment. |
| Bot | Run bot tests, systemd health checks and real Telegram callback checks. |

---

## 15. Owner’s expected application behavior

The owner expects a polished application that a non-technical user can operate without leaving the dashboard. A user should be able to open the app, select a subscription, select a route, choose TUN or proxy mode and connect. The app must explain errors in human language, show connection status truthfully and never claim “Active” after a failed connection.

Smart Groups must be visually indistinguishable from ordinary routes except for their generic Type label. Pool nodes must remain private. Route selection must be local, adaptive and failover-capable. VPS load must stay low even with many users.

The application should feel like a cohesive Mosaic product across Windows, Linux and Android: dark and light themes, Russian and English localization, responsive layouts, custom iconography, clean tray controls, accessible mobile controls, no clipped text, no default Flutter branding, no mocks in production and no duplicate account/subscription models.

---

## 16. Immediate backlog for the next agent

1. Publish only clearly labelled validation artifacts until Windows build and production Android signing are complete.
2. Run the Windows build on a Windows host and produce installer plus portable archive using the same version metadata.
3. Install Android APK on a physical test device and verify VPN permission, tunnel establishment, direct routing, disconnect and recovery.
4. Replace the temporary Android validation key with the protected production signing configuration.
5. Update site download cards only after the matching release assets exist; remove stale version labels and dead links.
6. Confirm the real VPS deployment path and deploy site/bot changes with backup and rollback.
7. Run bot and backend integration tests against non-production or explicitly approved test accounts.
8. Add automated CI for Flutter analyze, Flutter tests, Go tests, Linux build and Windows/Android builds.
9. Keep `Free LTE` disabled until an authorized source and review exist.
10. Preserve the direct client-to-node architecture and never route user traffic through the MosaicVPN VPS.

---

## 17. Safe operating rules

Never commit or publish credentials. Never paste production tokens into logs, README files, issues, releases or client bundles. Never claim a validation-signed APK is a production release. Never expose pool node lists to users. Never add hidden whitelist-bypass discovery logic under the Free LTE placeholder. Always create a backup before changing VPS site files, bot code, database schemas or payment callbacks. Always test rollback and verify health after deployment.

> The correct definition of “done” for MosaicVPN is not merely a successful compile. It is a verified, signed, platform-specific client that connects through the intended direct route, uses the shared account model, renders server-defined Smart Groups correctly, survives node failure, does not overload the VPS and has a reproducible rollback path.
