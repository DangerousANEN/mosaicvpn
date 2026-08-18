# MosaicVPN: подтверждённые findings для исправления enrollment, Smart Groups, туннелирования и Routes

Дата: 2026-08-18

## Наблюдаемые дефекты

1. Website-to-app enrollment открывает приложение, однако на desktop создаётся карточка `Импортированная подписка` с нулём маршрутов и сообщением, что совместимый кабинет не объявлен.
2. Smart Groups не появляются внутри website-added MosaicVPN subscription.
3. Попытка подключения отображает `DioException` с HTTP 400 без тела ответа daemon API.
4. Таблица маршрутов содержит нежелательные checkbox controls, выводит `Авто` в колонке ping до фактического измерения, не имеет нужных операторских колонок и не поддерживает настраиваемые колонки.
5. Existing test-all endpoint делает параллельный пакетный probe и возвращает только финальный список; в нём нет progress stream, cancellation job и single-active-job arbitration.

## Подтверждённые первопричины

### A. Desktop enrollment теряет provider identity

`MosaicEnrollmentExchange.redeem()` получает из hosted API корректные поля `provider_id`, `provider_account_id`, `subscription_name` и `subscription_url`. Однако desktop `AppShell._completeDesktopWebsiteEnrollment()` затем вызывает общий `DaemonApi.addSubscription(name, url)`. Его JSON contract передаёт только `name`, `url`, `auto_refresh` и `refresh_interval_seconds`.

`internal/api.handleAddSub()` создаёт `proto.Subscription` без `Source`, `ProviderID`, `ProviderAccountID` и `HidePhysicalNodes`. Поэтому `internal/api.refresh()` классифицирует subscription как обычный imported feed. Для ordinary import `ParseManifestOrSynthesize()` намеренно возвращает raw feed без provider manifest decoration. Это напрямую объясняет одновременно:

- `Imported subscription` вместо MosaicVPN provider source;
- отсутствие cabinet capability;
- ноль Smart Groups;
- риск появления ordinary physical routes вместо provider-owned virtual group rows.

Android имеет отдельный правильный method `AndroidHostedDaemonApi.completeWebsiteEnrollmentIfPresent()`: он сохраняет source=`provider`, providerId, providerAccountId, hidePhysicalNodes=true и canonical provider subscription metadata. Desktop flow его не использует и эквивалентного daemon endpoint не имеет.

### B. Smart Groups существуют в backend, но для provider source only

Hosted endpoint `/api/manifest.json` возвращает public provider manifest; prior production verification showed seven groups. Desktop daemon supports subscription-scoped manifests in `GET /v1/manifest?subscription_id=...`, keeps them in `SaveManifestForSubscription`, builds virtual Smart Group rows and hides pool nodes when `Source == provider` / `ProviderID != ""`. But those branches are skipped for website-created generic subscription.

### C. HTTP 400 cannot be diagnosed from current UI

Desktop `DaemonApi.connect()` and `connectGroup()` issue `POST /v1/connect` and let Dio throw. API converts `state.Manager.Connect()` error to HTTP 400 in `handleConnect`. The displayed screenshot therefore loses `{"error":"..."}` with the actual reason. Possible classes are deliberately not treated as diagnosed until captured: unknown/missing selected route, provider source with empty routes, invalid generated sing-box config, missing runtime/privilege, or endpoint/server validation error.

The existing code must first surface structured error details and persist correlated diagnostics before a specific runtime fix is selected.

### D. Existing bulk test does not meet the requested interaction model

`POST /v1/servers/test-all` probes each target in parallel (concurrency 16) and returns only after every probe completes. It has no job ID, event stream, cancellation endpoint, per-result event or global gate. It cannot safely offer live `xx/xx`, ordered row updates or `Stop testing` semantics. It must be replaced or augmented by a daemon-owned test job protocol.

### E. Current Flutter DataTable behaviour explains unwanted controls

Flutter `DataTable` renders a checkbox column when rows have selection handlers unless `showCheckboxColumn` is explicitly false. It also auto-sizes columns and performs a double layout pass, making it a poor fit for an information-dense route table with desktop resizing and mobile presentation. The UI should use a separate route view model and a virtualized desktop table plus mobile route cards, not force a single fixed table across sizes.

## Research anchors

1. sing-box TUN documentation: desktop TUN needs the system privileges/capabilities, `auto_route` and an explicit loop-avoidance strategy (`route.auto_detect_interface` or `route.default_interface` / outbound bind). Linux `auto_redirect` is recommended alongside auto_route. <https://sing-box.sagernet.org/configuration/inbound/tun/>
2. sing-box route documentation: `auto_detect_interface` is the supported Windows/Linux/macOS setting to bind outbound connections to the default NIC and prevent a TUN routing loop. <https://sing-box.sagernet.org/configuration/route/>
3. sing-box URLTest: supplies group-level outbound selection using a defined test URL, interval and tolerance; it should be used for group auto-selection after the app has validated route material. <https://sing-box.sagernet.org/configuration/outbound/urltest/>
4. sing-box VLESS: production config needs required `server`, `server_port`, `uuid`, compatible TLS and transport fields; fields invalid for bundled sing-box must be rejected before start. <https://sing-box.sagernet.org/configuration/outbound/vless/>
5. Flutter DataTable docs identify automatic sizing/double layout and recommend virtualized alternatives for large tables. <https://api.flutter.dev/flutter/material/DataTable-class.html>
6. `data_table_2` demonstrates fixed headers/widths but explicitly does not implement user resize or column rearrangement. It is therefore not a full solution for requested desktop UX. <https://github.com/maxim-saplin/data_table_2>
7. Syncfusion DataGrid example demonstrates a technical pattern for persisted widths and resize callbacks; a license/dependency decision is needed before adoption. <https://github.com/SyncfusionExamples/How-to-add-delete-and-resize-columns-in-Flutter-DataTable>

## Validation completed before planning

- `go test ./internal/api ./internal/state ./internal/subs ./internal/store` passes.
- Existing tests prove that Smart Group primitives compile, but they do not cover website enrollment of desktop provider metadata, a real production subscription refresh, user-visible manifest association, a connected desktop TUN route, nor the requested cancellable progressive group-test protocol.

## Safety and product constraints retained

- Smart Groups must be visible as normal provider subscription routes.
- Private pool nodes must not reach the user UI.
- Provider-specific cabinet attachment must occur after subscription addition or through website enrollment.
- No claim about successful connection is valid until physical Windows/Linux/Android validation captures the full daemon response and runtime logs.
- Public text must remain neutral with respect to connection protection, privacy, encryption and route quality.
