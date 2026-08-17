# MosaicVPN v0.3.18: подписки, профили и подключение

**Статус:** утверждённый технический design перед реализацией.  
**Принцип:** **подписка является первичной**, а профиль/кабинет — необязательной привязкой к конкретной подписке. Ни UI, ни native runtime не должны иметь глобального singleton-аккаунта как источника сетевого доступа.

## 1. Инварианты продукта

| Инвариант | Реализация |
|---|---|
| У пользователя может быть много подписок и профилей разных провайдеров | `Subscription` остаётся отдельной записью. Состояние кабинета хранится и выбирается по `subscriptionId`. |
| У одной подписки ноль или один активный профиль-кабинет | Локальная `SubscriptionProfileLink` привязана к `subscriptionId`; повторная привязка обновляет link, а не создаёт новую подписку. |
| MosaicVPN provider-source не раскрывает private pool | Provider subscription отображает только server-signed `ManifestGroup` rows. Client-side config selector получает opaque authenticated feed, но не передаёт raw node rows в UI. |
| Маршрут может быть включён с любого экрана и платформы | Каждый route action вызывается через platform-aware `ConnectionCoordinator`; виджет не делает daemon/native dispatch напрямую. |
| Успех равен подтверждённой готовности, а не старту операции | Desktop ждёт успешный daemon/sing-box API result; Android вызывает `startAndAwaitReady()`. UI writes `connected` только после terminal success. |
| Проблема не маскируется | `RuntimeFailure` сохраняет код, безопасное описание, технический reason и repair hint. |

## 2. Миграция модели профиля

### Новые Dart-модели

```dart
enum SubscriptionCabinetKind { none, generic, managedProvider }

class SubscriptionProfileLink {
  const SubscriptionProfileLink({
    required this.subscriptionId,
    required this.providerId,
    required this.providerAccountId,
    required this.cabinetKind,
    required this.linkedAt,
    this.displayName = '',
    this.capabilities = const <String>{},
    this.cachedSummary,
    this.cachedAt,
  });

  final String subscriptionId;
  final String providerId;
  final String providerAccountId;
  final SubscriptionCabinetKind cabinetKind;
  final DateTime linkedAt;
  final String displayName;
  final Set<String> capabilities;
  final SubscriptionCabinetSummary? cachedSummary;
  final DateTime? cachedAt;
}
```

`Subscription` **не получает bearer/session token**. Токены остаются в secure storage, а link хранит только provider/account identifier и состояние capabilities. Это позволяет хранить subscriptions в portable/data JSON без секретов.

### Локальное хранение и совместимость

| Текущий ключ/источник | Новая роль | Миграция |
|---|---|---|
| `mosaic.android.subscriptions.v1` | список Android subscriptions | Версия `v2`: сохранить existing rows как есть; не создавать `provider-mosaicvpn-primary` при восстановлении сессии. |
| Android secure storage `mosaic_android_*` | device credential for managed Mosaic adapter | При первом запуске с валидной сессией найти существующую MosaicVPN subscription по providerId; если её нет, создать один managed subscription только в explicit migration. Создать `SubscriptionProfileLink` именно к ней. |
| Desktop store `ProviderAccounts` | provider credential registry | Map `provider_account_id` → `subscription_id`; legacy account link должен быть трансформирован в subscription-scoped mapping. |
| `UnifiedAccount` | managed Mosaic cabinet payload | Не использовать как global Riverpod provider. Загружать через family keyed by `subscriptionId`. |

## 3. Контракт подключения

### Общая модель ссылки на маршрут

```dart
class SubscriptionRouteRef {
  const SubscriptionRouteRef({
    required this.subscriptionId,
    required this.routeId,
    required this.kind,
    this.importUri,
  });

  final String subscriptionId;
  final String routeId;
  final RouteKind kind; // providerSmartGroup | importedServer | localGroup | localServer
  final String? importUri;
}
```

### Координатор

```text
UI gesture
  → ConnectionCoordinator.connect(ref)
  → mutex: cancel/reject concurrent switch
  → resolve subscription and source capability
  → stop active tunnel when required
  → desktop: DaemonApi connect/connectGroup
    Android provider Smart Group: buildNativeTunConfig(groupId) → permission → startAndAwaitReady
    Android imported/local server: buildNativeTunConfigFromShareUri(importUri) → permission → startAndAwaitReady
  → if and only if terminal state == connected: publish connected
  → otherwise: publish typed RuntimeFailure and retain last known non-connected route state
```

`SmartGroupSelector` cannot be called on Android with an `UnavailableDaemonApi`; it must either delegate to `ConnectionCoordinator` or be used only by the desktop adapter. For provider groups on Android the config retains URLTest/failover but is filtered to the signed `mosaic_group_ids` membership before start.

### Typed errors

| Code | Source condition | User-facing repair |
|---|---|---|
| `vpnPermissionDenied` | Android `prepare` false | «Разрешите создание VPN-подключения в системном окне Android.» |
| `configInvalid` | parser/native `validateConfig` failure | «Маршрут содержит неподдерживаемые параметры. Обновите подписку или выберите другой маршрут.» |
| `subscriptionUnavailable` | remote feed cannot load or is empty | «Источник не вернул рабочие маршруты. Проверьте ссылку и обновите подписку.» |
| `runtimeStartupFailed` | daemon/libbox terminal error | «Среде VPN не удалось запуститься. Откройте детали и повторите после остановки другого VPN.» |
| `runtimeTimeout` | no terminal state within 12 sec | «VPN не подтвердил запуск за 12 секунд. Повторите попытку или перезапустите приложение.» |
| `routeUnsupported` | parser capability rejects route | «Этот протокол или transport пока не поддержан текущей платформой.» |

## 4. Устранение Android blocker

В `AndroidHostedDaemonApi` нужно **явно override** `connect(String serverId)` и `connectGroup(String groupId)`. Это защищает любые legacy callers, включая screens/tests, однако основное действие UI должно перейти в `ConnectionCoordinator`.

| Route type | Как получить config | Start path |
|---|---|---|
| MosaicVPN `ManifestGroup` | `AndroidMosaicAccountService.buildNativeTunConfig(groupId: group.id)` | `requestPermission()` → `startAndAwaitReady(config)` |
| User subscription server | Найти `Server` через `listServers()`, взять `importUri`, вызвать `buildNativeTunConfigFromShareUri` | `requestPermission()` → `startAndAwaitReady(config)` |
| Local server | Получить `Server` from local storage / normal API, same imported config builder | `requestPermission()` → `startAndAwaitReady(config)` |
| Local group | Resolve member routes deterministically; if Android implementation supports one final URLTest config, use a client-built route config; otherwise mark group unavailable with explicit reason, never generic daemon error | same start contract |

The methods return only when native state is `connected`; state `error` is translated into a thrown typed failure. `disconnect()` must be overridden to call `AndroidVpnService.stop()` and require a terminal disconnected state.

## 5. Navigation and cabinet UX

### Replace global account tab

`AccountScreen` becomes `AccountsScreen` and is an **index**, not a cabinet. It contains one card per subscription with:

| Card data | Source |
|---|---|
| subscription name + provider/local type | `Subscription` |
| cabinet state: attached / not attached / generic metadata | `SubscriptionProfileLink` and feed metadata |
| expiry/traffic if available | cached generic or managed summary |
| quick action | `Open subscription profile` or `Attach profile` |

The app shell must replace `AccountScreen` in `_mainPages` and `_allPages`; `MoreScreen` must do the same. `ProviderProfileScreen` and the global `BillingScreen` must be removed from everyday navigation once features are reachable from `SubscriptionCabinetScreen`.

### Capability menu, all subscriptions

`_SourceTabs._showContextMenu` must remove the early return for `isProviderSource`. Build `PopupMenuEntry` values conditionally from `SubscriptionActionCapabilities`:

1. **Обновить** — URL or provider manifest exists.
2. **Копировать ссылку** — subscription URL exists.
3. **Открыть в браузере** — http/https URL.
4. **Редактировать** — mutable imported/local subscription only.
5. **Удалить / отключить** — delete for local/imported; explicit unlink confirmation for a managed provider subscription.
6. **Поделиться** — exportable URL exists.
7. **Открыть профиль подписки** — always present.

This menu must be available both from mouse secondary click and the visible overflow button of every tab, including provider-pinned tabs. The summary wallet icon must also always open `SubscriptionCabinetScreen`; unsupported subscriptions show a generic read-only summary and attach affordance rather than hiding the action.

## 6. Provider and generic cabinet resolution

```text
SubscriptionCabinetScreen(subscriptionId)
  → resolve SubscriptionProfileLink
  → managed provider adapter?  → cached managed CabinetSummary immediately
                               → coalesced background refresh
  → generic subscription?      → parse cached metadata/expiry where available
                               → show «Подключить кабинет», provider-neutral
```

The Mosaic adapter is one implementation of `SubscriptionCabinetAdapter`; it cannot be hard-coded by `providerId` in the screen. A non-Mosaic subscription initially exposes a generic cabinet panel, including subscription URL, item count, last refresh/error, and parsed expiry/traffic metadata if available.

## 7. Cache and loading budget

| Requirement | Implementation |
|---|---|
| First render | Persist a small redacted summary keyed by `subscriptionId`; display it synchronously/within one provider read. |
| Background refresh | `AsyncNotifier.family` deduplicates in-flight requests per subscription; cache has a 60-second fresh TTL and 10-minute stale grace. |
| Network calls | Managed Mosaic summary endpoint is one aggregate call; payment history is fetched lazily after summary is rendered. |
| Failed refresh | Keep last successful summary visible with «обновление не удалось» timestamp, not a blank cabinet. |
| Website login latency | Store `isExchangingWebsiteCode` independently from `isLaunchingBrowser`; consume deep link once per callback; exchange immediately on `onNewIntent` and resume, no extra 5–10-second refresh pipeline. |

## 8. Website “Add to app” enrollment

1. Cabinet page calls `/api/app-auth/issue` with purpose `enroll` and a high-entropy `state`; existing server session is reused.
2. Website redirects to `mosaicvpn://enroll/callback?code=...&state=...`.
3. `MainActivity` persists a separate pending enrollment callback (never overwrite login callback).
4. Flutter verifies state and exchanges code at `/api/app-auth/exchange` (or dedicated `/api/app-enroll/exchange` if server needs stricter semantics).
5. Response contains provider identity, display name and subscription URL/direct token. App transactionally creates/updates the managed `Subscription` then writes its `SubscriptionProfileLink`.
6. App opens the created subscription and its cabinet. Repeated enrollment is idempotent by provider account id.

## 9. Required test matrix

| Level | Cases |
|---|---|
| Dart unit | URI parser: VLESS Reality + transport, Trojan, VMess base64, Shadowsocks SIP002/legacy; malformed/unsupported input returns typed reason. |
| Dart unit | Android `connect`, `connectGroup`, `disconnect`: permission denied, config invalid, native error, timeout and terminal connected. |
| Widget | Context menu displays all applicable actions for provider, imported and local subscriptions; profile action always present. |
| Widget | Accounts index has multiple linked/unlinked subscriptions and no singleton cabinet. |
| Widget | Cached cabinet renders before delayed refresh and preserves cached content on error. |
| Go | Existing daemon runtime health and provider manifest subscription scoping remain green. |
| Linux smoke | import supported URI → native daemon ready → DNS resolution → stop → no stale connected state. |
| Android emulator/device | first permission, deny permission, connect Smart Group, connect import, rotate network, stop, second start. |

## 10. File-level implementation map

| File | Required modification |
|---|---|
| `flutter/lib/core/api/android_hosted_daemon_api.dart` | Implement `connect`, `connectGroup`, `disconnect`; update source storage migration; resolve imported server IDs. |
| `flutter/lib/core/services/android_mosaic_account_service.dart` | Add explicit config methods for provider and imported routes; split auth/enrollment callbacks; never conflate session with subscription creation. |
| `flutter/lib/core/services/android_vpn_service.dart` | Add typed terminal-state translation helper; retain existing `startAndAwaitReady`. |
| `flutter/lib/core/services/connection_coordinator.dart` (new) | One cross-platform route dispatch and serialization boundary. |
| `flutter/lib/core/models/subscription_profile_link.dart` (new) | Redacted subscription-scoped link and summary schema. |
| `flutter/lib/core/providers/subscription_profile_providers.dart` (new) | `family` cache/refresh providers keyed by subscription ID. |
| `flutter/lib/features/groups/groups_screen.dart` | Build `SubscriptionRouteRef`, delegate to coordinator, rework tab context menu and universal cabinet entry. |
| `flutter/lib/features/groups/subscription_cabinet_screen.dart` | Use subscription-scoped adapter/cached providers; generic fallback not hard-coded Mosaic gate. |
| `flutter/lib/features/account/account_screen.dart` | Replace with Accounts index and move auth attach UI to the selected subscription context. |
| `flutter/lib/app/app_shell.dart`, `more_screen.dart` | Replace Account navigation target/name; remove parallel global cabinet entry. |
| `flutter/android/.../MainActivity.kt`, `AndroidManifest.xml` | Separate enrollment deep link lifecycle. |
| `site/cabinet.html`, `bot/bot.py` | Issue/exchange enrollment codes and present «Добавить в приложение». |

## References

The underlying research record with references to Throne and Exclave is stored in [`THRONE_EXCLAVE_RESEARCH_FOR_V0318.md`](./THRONE_EXCLAVE_RESEARCH_FOR_V0318.md). Concepts are adopted independently; GPL source code is not copied.
