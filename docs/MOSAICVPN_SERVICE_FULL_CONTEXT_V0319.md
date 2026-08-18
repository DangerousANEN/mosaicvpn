# MosaicVPN — полный технический контекст, карта сервиса и продуктовые требования

**Версия документа:** v0.3.19 working context, 18 августа 2026 года  
**Назначение:** передача полной картины владельцу, разработчику или следующему агенту без повторного исследования истории проекта.  
**Основной репозиторий:** [DangerousANEN/mosaicvpn](https://github.com/DangerousANEN/mosaicvpn)  
**Публичный домен:** [https://sub.zxc1x1.ru](https://sub.zxc1x1.ru)  
**Telegram-бот:** [@mosaicvpnbot](https://t.me/mosaicvpnbot)

> Этот документ намеренно **не содержит** Telegram Bot Token, ключей Remnawave и Lava.ru, SSH private keys, Android/Windows signing keys, паролей, database credentials, web-session tokens или subscription links. Они должны находиться только в защищённом env/secret store владельца. Никогда не помещать их в Git, документацию, логи, скриншоты, release notes или клиентские сборки.

---

## 1. Что такое MosaicVPN

MosaicVPN — единая экосистема сервиса защищённого сетевого доступа. Она объединяет кроссплатформенный клиент, Telegram-бот, веб-сайт, веб-кабинет, биллинг и provider-oriented архитектуру подписок. Одна учётная запись пользователя должна быть доступна в Telegram, на сайте и в приложении, а действия, влияющие на доступ, синхронно отражаются во всех трёх точках.

Сервис не должен строиться по модели `клиент → VPS MosaicVPN → внешний сервер`. Пользовательский трафик идёт **напрямую с устройства пользователя через выбранный route/node**. VPS используется как control plane: он выдаёт account data, subscription metadata, платежные API, provider manifest, допускает/отсекает источники и публикует статический сайт. Он не должен быть центральным транзитным прокси для пользовательского трафика.

Ключевая пользовательская модель: **«Подписка → Маршрут → Подключение»**. Подписка может быть MosaicVPN provider subscription, сторонней удалённой подпиской или локальным сборником серверов. Маршрут может быть одиночным сервером либо Smart Group. Пользователь не должен видеть private pool nodes MosaicVPN.

---

## 2. Бизнес-модель и единый аккаунт

Базовая модель тарификации — **1 ₽ за 1 день доступа**. Сайт и бот предлагают пополнение на 10 дней, 30 дней и на произвольную сумму. Денежные расчёты, скидки, начисление дней и idempotency должны выполняться на сервере; клиент не является источником истины для баланса.

Пробный доступ выдаётся через Telegram при выполнении обязательных условий. Администратор должен иметь возможность управлять списком обязательных Telegram-каналов. Аккаунт должен поддерживать freeze/unfreeze, просмотр баланса, предполагаемого следующего списания, срока доступа, трафика, устройств, статистики, истории платежей и безопасную ротацию subscription link при её утечке.

| Входная точка | Обязательные возможности |
|---|---|
| Telegram-бот | Регистрация, trial, профиль, баланс, платежи, freeze, link rotation, поддержка, уведомления. |
| Веб-кабинет | Вход, ID аккаунта, баланс, срок, платежи, устройства, пополнение, административный вход для владельца. |
| Клиент | Подключение, выбор subscription/route, website-first sign-in, per-subscription cabinet, top-up через сайт/checkout, freeze, устройства, платежи, link rotation. |

---

## 3. Репозиторий и карта исходников

Главный код находится в GitHub repository `DangerousANEN/mosaicvpn`. Активный клиентский стек — Flutter. В README могут оставаться исторические Tauri/React references; они не являются текущим runtime-контуром и не должны смешиваться с Flutter без отдельного миграционного решения.

| Путь | Роль |
|---|---|
| `cmd/mosaicd/` | Точка входа desktop daemon `mosaicd`. |
| `cmd/mosaic/` | CLI для локального daemon API. |
| `internal/api/` | Local loopback HTTP API daemon: status, subscriptions, manifest, groups, connection, diagnostics. |
| `internal/state/` | Daemon state machine, sing-box lifecycle, RuntimeHealthBackend, unexpected-exit handling. |
| `internal/subs/` | Парсинг feeds, provider manifest, group synthesis/resolution. |
| `internal/proto/` | Канонические Go models: subscriptions, provider accounts, Smart Groups, policy, health. |
| `internal/store/` | Persistent state, migration v3, per-subscription `ProviderManifests`. |
| `internal/pool/` | Admission filtering, pool health/pruning и candidate handling. |
| `internal/single/` | Single-instance enforcement. |
| `flutter/` | Основной Flutter клиент Windows/Linux/Android. |
| `flutter/lib/core/api/` | Desktop daemon client и Android hosted facade. |
| `flutter/lib/core/services/` | Android VPN bridge, account API, Smart Group selector, tray, locks. |
| `flutter/lib/features/dashboard/` | Главный connection dashboard. |
| `flutter/lib/features/groups/` | Экран подписок/маршрутов и subscription-scoped cabinet. |
| `flutter/lib/features/account/` | «Аккаунты» — индекс профилей конкретных подписок, а не singleton cabinet. |
| `flutter/android/` | Kotlin `MosaicVpnService`, `MainActivity`, manifest, icons, libbox integration. |
| `bot/bot.py` | Telegram bot, SQLite state, billing API, browser session authority, web-cabinet API. |
| `site/` | Public landing, web cabinet, legal pages, provider docs, release download cards. |
| `docs/` | Архитектурные документы, research и handoff. |
| `.github/workflows/` | Tag-triggered release CI: Windows Setup/Portable, Linux DEB/TAR.GZ, signed Android APK. |

---

## 4. Клиенты: платформы и архитектура

### 4.1 Общая Flutter модель

Клиент является универсальным: он должен уметь работать с MosaicVPN и сторонними подписками, не превращая каждую внешнюю подписку в Mosaic account. Основные модели:

| Модель | Назначение |
|---|---|
| `Subscription` | Источник route inventory. Содержит `source`, `providerId`, `providerAccountId`, `hidePhysicalNodes`, URL, refresh state. |
| `Server` | Одиночный импортированный/локальный server profile. |
| `ServerGroup` | Локальная пользовательская коллекция серверов. |
| `ProviderManifest` | Server-provided набор Smart Groups и provider metadata. |
| `ManifestGroup` | Одна Smart Group: title, type, policy, disabled state, description, icon, opaque nodes. |
| `UnifiedAccount` | Данные управляемого кабинета: balance, expires, traffic, devices, freeze, statistics. |
| `AndroidMosaicSession` | Android Keystore-backed direct token, browser session token и provider enrollment metadata. |

Для неподготовленного пользователя основной экран — Dashboard: выбрать subscription, выбрать route, нажать «Подключить». Расширенные functions не должны мешать базовому flow. Пользователь не должен получать ложный success state после неудачного запуска.

### 4.2 Desktop: Windows и Linux

Desktop использует `mosaicd`, запускающий sing-box и предоставляющий HTTP API только на loopback interface. Lockfile содержит bearer token, port, PID и runtime metadata. Flutter daemon client восстанавливает endpoint через lockfile при retryable error.

`mosaicd` и sing-box должны завершаться при полном quit приложения. При включённой настройке close-to-tray окно скрывается, но runtime продолжает работу. Tray должен быть стилизован под Mosaic, иметь Connect/Disconnect, Open routes, Quick panel и Quit. Portable build обязан хранить data directory внутри собственной portable folder. Одновременно должно работать не более одного instance.

### 4.3 Android

Android не запускает desktop `mosaicd`. Он использует Kotlin `MosaicVpnService` и bundled GPLv3 `libbox.aar`/sing-box runtime. Flutter взаимодействует с Android по `MethodChannel` `ru.mosaicvpn.mosaic_vpn/android_vpn`.

Обязательный Android connection contract:

1. Flutter запрашивает VPN permission.
2. Клиент собирает sing-box JSON с Android TUN inbound и выбранным outbound/Smart Group.
3. `validateConfig` проверяет JSON в native runtime до service start.
4. `startAndAwaitReady` ждёт terminal `connected` либо `error`, а не считает начальный `connecting` успехом.
5. При error service сохраняет diagnostic reason, а UI показывает его человеческим текстом.
6. Disconnect реально останавливает `MosaicVpnService`.

Актуальная исправляемая ошибка Android: VLESS URI часто содержит `encryption=none`, но это **URI compatibility parameter**, а не поле sing-box VLESS outbound. В sing-box 1.13 VLESS outbound не принимает top-level `encryption`; такое поле даёт `outbounds[0].encryption: json: unknown field "encryption"`. Builder должен его удалять. Поддерживаемые VLESS outbound fields включают `server`, `server_port`, `uuid`, `flow`, `network`, `tls`, `packet_encoding`, `multiplex`, `transport`.[1]

---

## 5. Smart Groups и приватность пула

Smart Group — virtual route row. Она выглядит в таблице как обычный route с type **«Smart Group / Смарт-группа»**, но конкретное название, политика, тип и ограничение приходят с provider manifest. Примеры: «Минимальный пинг», «Оптимальный», «Максимальная скорость», «Локальные сервисы (RU)», «Германия», «Канада».

Физические MosaicVPN pool nodes **никогда не показываются** в UI. Provider source с `hidePhysicalNodes=true` должен отображать только `ProviderManifest.groups`. Сторонняя подписка может отображать свои обычные VLESS/SS/Trojan rows, а local collection — созданные пользователем profiles.

### 5.1 Manifest contract

```json
{
  "provider_name": "MosaicVPN",
  "user_tier": "standard",
  "groups": [
    {
      "id": "rg-all",
      "title": "Минимальный пинг",
      "route_type": "smart_group",
      "type": "urltest",
      "pool_id": "mosaicvpn",
      "category": "smart",
      "client_policy": {
        "mode": "latency",
        "shard_size": 16,
        "max_parallel_probes": 4,
        "probe_ttl_seconds": 600,
        "max_failover_tries": 3
      }
    }
  ]
}
```

`internal/store` уже поддерживает manifests per subscription via `ProviderManifests[subscriptionID]`. Desktop daemon `handleGetManifest` умеет принимать `?subscription_id=...`. Слабое место, выявленное 18 августа 2026 года: Android hosted authority обращался к `/api/manifest.json`, но deployment его не предоставлял (HTTP 404); поэтому imported Mosaic feed рендерился как обычный VLESS list, а Smart Groups не появлялись. В рабочем контуре endpoint должен существовать и отдавать только group metadata, не pool links.

### 5.2 Выбор маршрута

VPS выполняет лёгкий admission filtering и отсекает мусорные/offline candidates. Device выполняет client-side probe/ranking по своей сети: latency, loss, stability, jitter и, при разрешённой policy, ограниченный HTTPS speed probe. Ookla не использовать из-за нестабильности/блокировок в целевых сетях. `SpeedProbePolicy` ограничивает размер, timeout и число проверяемых candidates.

На устаревшем plain subscription feed без `mosaic_group_ids` Android compatibility layer может применять group policy к authenticated opaque candidate set. При наличии explicit group-membership metadata она является authoritative: client не должен расширять subset и не должен показывать nodes.

Категория **«Свободный LTE»** остаётся disabled placeholder `reserved-lte-compat`. В ней нет скрытой implementation, нет discovery logic, нет активного профиля. Включать её можно только после отдельного owner-authorized/compliance-reviewed source.

---

## 6. Подписки, профили и per-subscription cabinet

Принцип: **аккаунт не равен подписке**. У приложения может быть много subscriptions от разных providers. Каждый subscription может иметь свой provider cabinet capability.

| Сценарий | Ожидаемое поведение |
|---|---|
| Внешняя subscription URL | Добавляется как отдельная subscription, показывает доступные feed metadata и imported routes. |
| Локальный сборник | Пользователь создаёт collection, добавляет profile вручную, из буфера, файла, QR или subscription. |
| MosaicVPN URL `https://sub.zxc1x1.ru/<opaque>` | Распознаётся как Mosaic provider source, private raw rows скрываются, доступны Smart Groups и пункт cabinet. |
| Provider source без browser-enrolled profile | Cabinet объясняет, что нужно привязать профиль через сайт/Telegram, а не заявляет «provider не поддерживается». |
| Website «Добавить в MosaicVPN» | Создаёт/обновляет managed provider subscription и прикрепляет authenticated profile на устройстве. |
| Сторонний provider с capability adapter | Cabinet использует adapter; без него показывает безопасный generic profile, не подменяя данные. |

Контекстное меню каждой subscription обязано содержать: Refresh, Copy Link, Open in Browser, Share, Open subscription profile/cabinet. Rename/Delete доступны только mutable non-provider sources. Provider subscription не должна терять context menu.

---

## 7. Website-first login и Add-to-app enrollment

Основной метод входа — через сайт. Telegram `/link` code остаётся secondary fallback.

### 7.1 Browser login

1. App генерирует cryptographically random `state` и сохраняет его в Android Keystore-backed secure storage.
2. App открывает `https://sub.zxc1x1.ru/cabinet.html?return_to=...&state=...`.
3. Site использует existing web session либо просит пользователя войти.
4. Site вызывает `/api/app-auth/issue` и получает short-lived one-time code.
5. Browser возвращает только `code` и `state` в app callback; browser session token не помещается в URI.
6. App сверяет state locally and server-side, обменивает code через `/api/app-auth/exchange`, stores direct/session tokens securely.

### 7.2 Explicit Add-to-app

Web cabinet кнопка **«Добавить в MosaicVPN»** должна выдавать `purpose=enroll` code через тот же one-time code storage, после чего возвращать `mosaicvpn://enroll/callback?code=...&state=...`. Backend подтверждает purpose, expiry, state and single-use before returning account/subscription metadata.

Надёжность callback требует трёх уровней: intent filter, cold-start pending callback и immediate warm-app event. `MainActivity` должен сохранять `pendingEnrollmentCallback`, а также вызвать Flutter MethodChannel event `enrollmentCallbackReceived` при `onNewIntent`. `AppShell` подписывается на event, serialises completion and invalidates subscriptions/manifest/account providers. Это исправляет case, когда Android доставляет VIEW intent в уже resumed activity, а Flutter lifecycle `resumed` не меняется.

Flutter default deep link handler не должен одновременно перехватывать те же custom callbacks, если callback parsing реализован вручную в native bridge. Для этого в Android manifest выставляется `flutter_deeplinking_enabled=false`.[2]

Для дальнейшего production hardening следует внедрить verified HTTPS Android App Links на `sub.zxc1x1.ru`: `android:autoVerify="true"`, `https` intent filter и корректный `/.well-known/assetlinks.json` с SHA-256 signing certificate. Custom scheme остаётся compatibility fallback. Android official guidance рекомендует App Links для domain owned by service, поскольку custom scheme не гарантирует routing и не подтверждает владение доменом.[3]

---

## 8. Telegram bot и hosted account API

`bot/bot.py` одновременно содержит Telegram bot и HTTP API на VPS. База данных SQLite хранит users, pairing/link codes, browser sessions, one-time `app_auth_codes`, history and administrative records. `app_auth_codes` должны быть short-lived, state-bound и single-use. Поле `purpose` различает `login` и `enroll`.

Ключевые hosted endpoints:

| Endpoint | Назначение |
|---|---|
| `POST /api/link/redeem` | Telegram pairing code → direct token, session token, subscription URL. |
| `POST /api/session` | Web cabinet login via Telegram code. |
| `POST /api/app-auth/issue` | Выдача short-lived state-bound code для login/enroll. |
| `POST /api/app-auth/exchange` | Code exchange → account/session/direct subscription material. |
| `GET /api/manifest.json` | Public provider metadata only: Smart Group rows/policies, no pool nodes. |
| `GET /api/billing/profile` | Account balance and subscription state. |
| `GET /api/billing/payments` | Payment history. |
| `GET /api/checkout/options` | Available checkout providers. |
| `POST /api/checkout/create` | Creates Lava checkout response for mobile/client. |
| `POST /api/account/freeze` / `unfreeze` | Real provider access state change. |
| `POST /api/subscription/link/rotate` | Revokes previous short UUID and returns new link. |

Bot requirements: formal tone «вы», no broken star formatting, no ambiguous advertising text about internet blocking bypass, current legal documentation, safe payment webhooks, idempotent financial operations, controlled broadcasts and owner administration.

---

## 9. Website, legal pages и mobile cabinet

`site/` contains public landing and cabinet. Landing must look professional, have real Mosaic branding, responsive mobile layout, clear downloads, pricing, documentation and non-controversial compliance-safe copy. Mobile header must expose cabinet entry; tables and pricing text must not be clipped.

`site/cabinet.html` handles browser session and displays account ID, status, balance, traffic, access expiry, payments, devices, checkout, admin entry and Add-to-app action. It must not place long-lived credentials into links, browser history or DOM logs.

Legal pages include terms, privacy, offer, delivery and refunds. Refund policy must describe technical failure/non-delivery conditions and a claim deadline. Lava checkout must be presented as MosaicVPN checkout; customers should not be asked to create or top up a Lava account.

---

## 10. Payment stack

Lava.ru is used for site and Telegram bot stores, with separate shop identities and separate server-side secrets. Required payment paths: 10 days, 30 days, custom amount; SBP/card capability when enabled by provider; success/failure notifications; signature verification; idempotency; persisted invoice state; return URL; webhook validation.

No payment secret is allowed in Flutter, static HTML or GitHub. Price, discount and account crediting are server-side only. When payment method is unavailable, show an honest disabled/coming-soon state.

---

## 11. VPS and operations map

| Component | Production location / runtime |
|---|---|
| VPS | Existing Linux VPS owned by the service; exact IP and credentials intentionally omitted. |
| Bot | `/opt/mosaic-bot/`, systemd service `mosaic-bot.service`, SQLite and protected environment configuration. |
| Static landing/cabinet | `/etc/letsencrypt/landing/`, served at `sub.zxc1x1.ru`. |
| Bot HTTP API | Local port `12223`, proxied from nginx via `/api/`. |
| Remnawave | `/opt/remnawave/`, Docker-related panel/proxy/database components. |
| Nginx | Remnawave nginx/container proxy, responsible for public domain routing. |
| Desktop daemon | Runs only on the user’s device; never deploy as public egress/transit proxy. |
| GitHub Releases | Public binary distribution, tag-triggered CI. |

Deployment procedure must back up remote `bot.py` and static files, upload reviewed files, run `python3 -m py_compile`, restart `mosaic-bot.service`, validate service status and public HTTP endpoints. Never use `pkill`/`nohup` alongside systemd for the production bot.

---

## 12. Current release state and CI

Latest published release before the current incident work: **v0.3.18**, Git commit `6c0654e`, with five public assets: Android APK, Windows Setup, Windows Portable ZIP, Linux DEB and Linux Portable TAR.GZ. All five release links were HTTP-verified after publication.

Current v0.3.19 working tree fixes the user-reported Android incident and is **not yet published** at the time of this document. Release gates for the next tag:

1. `go test ./...`.
2. `flutter analyze`.
3. Full `flutter test`.
4. Android release APK build.
5. Validate generated sing-box config with bundled Linux sing-box where possible.
6. Deploy bot manifest endpoint and validate `GET /api/manifest.json` returns group metadata.
7. Install APK on a physical Android device; test permission, direct server connect, dashboard Smart Group connect, routes Smart Group connect, disconnect, browser login and Add-to-app in both cold/warm app cases.
8. Verify website cards after GitHub artifacts publish.
9. Smoke test Windows installer/portable and Linux packages where respective host is available.

---

## 13. Research-derived patterns from Throne and Exclave

No GPL code is copied. The implementation adopts ideas, interfaces and lifecycle patterns only.

| Reference | Borrowed engineering pattern | MosaicVPN adaptation |
|---|---|---|
| Throne | Explicit profile lifecycle: construct config, start process, observe readiness, stop/cleanup, reflect true result in UI. | `mosaicd` RuntimeHealth and Android `startAndAwaitReady`; no optimistic active route after failure. |
| Throne | Profile-first operational model and rich context actions. | Subscription-first routes tabs, universal context menu, cabinet as a property of subscription rather than app-global singleton. |
| Throne | Clear separation of persisted profile data from execution process state. | `Subscription`, `Server`, local groups and Android secure session are separate from `VpnStatus` and `_activeRoute`. |
| Exclave | Android foreground VpnService ownership, native runtime validation, TUN lifecycle and platform-specific failure surface. | Kotlin `MosaicVpnService`, `validateConfig`, permission flow, runtime errors retained and presented by Flutter. |
| Exclave | Parse subscription/share URLs into normalized runtime config only at connection boundary. | Android share URI parser supports VLESS, Shadowsocks, VMess and Trojan; current incident adds strict sing-box field sanitisation. |
| Exclave | Service state should be authoritative instead of assuming service start equals connection. | Poll terminal runtime state before marking a route connected. |

---

## 14. Non-negotiable owner expectations

The product must be pleasant enough for a non-technical user yet retain advanced capability for power users. The basic user should not need to leave Dashboard to choose subscription, route and TUN/proxy behaviour. UI must have Mosaic branding, responsive layouts, correct Russian/English localisation, adaptive icon, dark/light themes, clear empty/error states and no mock data in production.

The service must support multiple provider accounts architecturally. Account tab must be **«Аккаунты»** or absent; cabinet must be subscription-scoped. Every subscription must expose context actions. Mosaic raw pool nodes must never be exposed. Smart Groups must live inside the matching provider subscription and must never appear as a separate «MosaicVPN Direct» pseudo-subscription.

Connection is a release-blocking feature: it must work via Dashboard and Routes on Windows, Linux and Android. Errors must retain concrete reason. If connection fails, route must not be marked active. User-visible error texts must be actionable, not generic `DioException` or `PlatformException` dumps.

---

## 15. Current known defects and active remediation

| Item | Current diagnosis | Remediation status |
|---|---|---|
| Android Routes `unknown field encryption` | VLESS URI parameter was emitted as unsupported sing-box JSON field. | Fixed in v0.3.19 working tree; regression test added. |
| Dashboard generic connection error | Dashboard duplicated Android runtime path and diverged from Routes facade. | Fixed in v0.3.19 working tree by routing both through `AndroidHostedDaemonApi`. |
| Website Add-to-app returns but does nothing | Warm activity callback depended on lifecycle resume only; custom callback could be consumed/ignored before Dart completion. | Event-driven `onNewIntent` → MethodChannel → AppShell completion added; Flutter default deep link interception disabled. |
| Manual Mosaic URL says cabinet unsupported | URL was classified as generic imported subscription. | Migration/recognition added for `sub.zxc1x1.ru/<opaque>` as protected Mosaic provider source. |
| Smart Groups absent | Android queried a public manifest endpoint that production did not serve (404). | Hosted `GET /api/manifest.json` added in working tree; deployment and physical-device verification pending. |
| Plain feed lacks custom membership metadata | Standard Remnawave feed contains VLESS rows only. | Compatibility behaviour applies provider policy to authenticated opaque set until explicit metadata endpoint/feed is introduced. |
| Physical Android smoke test | Cannot be completed without actual handset/ADB session. | Required after next APK release. |

---

## 16. Safe operating rules

1. Never commit or publicly log secrets.
2. Never expose private pool node rows in a provider subscription UI.
3. Never route ordinary user traffic through the Mosaic VPS as a transit proxy.
4. Never mark VPN active until platform runtime confirms `connected`.
5. Never turn on Free LTE placeholder without a separately approved and audited source.
6. Back up VPS files before deployment and restart service through systemd.
7. Treat web/browser callback codes as short-lived, one-time and state-bound.
8. Do not claim cross-platform production readiness until a physical Android, Windows and Linux connection smoke test passes.
9. Use server-defined Smart Group metadata; do not hard-code the user-facing Mosaic route catalog in generic Flutter UI.
10. Preserve payment idempotency and never trust client-supplied balance calculations.

---

## References

[1]: https://sing-box.sagernet.org/configuration/outbound/vless/ "sing-box VLESS outbound configuration"

[2]: https://docs.flutter.dev/ui/navigation/deep-linking "Flutter deep linking documentation"

[3]: https://developer.android.com/training/app-links/create-deeplinks "Android Developers: deep links and App Links"
