# MosaicVPN: план исправления enrollment, кабинета, Smart Groups, туннелирования и Routes

**Дата:** 18 августа 2026 года  
**Статус:** план подготовлен после исследования исходников, production-сценария и внешней документации. До завершения этапа диагностики изменение параметров TUN или sing-box «наугад» не допускается.

## 1. Краткий вывод

Переход сайта в клиент теперь работает: приложение получает одноразовый callback. Но на desktop следующий шаг выполняется неверно. Callback с корректными полями `provider_id`, `provider_account_id`, `subscription_name` и `subscription_url` превращается в обычный вызов добавления URL. В результате daemon сохраняет **generic imported subscription**, а не **MosaicVPN provider source**. Это одна первопричина сразу для трёх наблюдаемых симптомов: карточки «Импортированная подписка», отсутствия полного кабинета и отсутствия Smart Groups.

Ошибка подключения с HTTP 400 пока **не имеет установленной технической причины**. Текущий Flutter-клиент выбрасывает `DioException` и не показывает JSON-тело ошибки daemon. На стороне daemon HTTP 400 объединяет несколько разных классов сбоев: отсутствие/несоответствие выбранного маршрута, ошибка построения или проверки конфигурации, проблема native runtime, прав либо сетевого подключения. Первой задачей должен быть структурированный capture точной причины, а не замена настроек TUN вслепую.

| Приоритет | Блок | Результат |
|---|---|---|
| **P0** | Диагностика connection error | Пользователь видит короткую понятную причину, разработчик — correlation ID и безопасные runtime-логи. |
| **P0** | Provider enrollment | Website-added subscription создаётся как MosaicVPN provider source с привязанным кабинетом. |
| **P0** | Manifest/Smart Groups | Семь Smart Groups появляются внутри той же подписки; физические узлы пула не выдаются UI. |
| **P1** | Рабочий tunnel lifecycle | По результатам capture устраняются конкретные config/runtime/route ошибки для Windows, Linux и Android. |
| **P1** | Routes UX | Нормальная таблица без лишних checkbox, настраиваемые столбцы на desktop и route cards на mobile. |
| **P2** | Progressive latency testing | Один отменяемый тест за раз с `xx/xx`, живыми обновлениями и безопасной агрегацией Smart Groups. |
| **P2** | Callback fallback дизайн | Редкая fallback-страница приведена к визуальному языку основного Mosaic-сайта. |

## 2. Подтверждённые причины

### 2.1. Почему кабинет и Smart Groups не прикрепляются

Hosted API exchange уже возвращает canonical provider identity. На Android существует отдельный корректный путь, который сохраняет subscription с `source: provider`, `providerId`, `providerAccountId` и `hidePhysicalNodes: true`. Однако desktop callback вызывает общий `DaemonApi.addSubscription(name, url)`. Его контракт передаёт лишь имя и URL. В `handleAddSub` daemon создаёт subscription без provider metadata и без флага скрытия pool nodes.

Далее `refresh()` намеренно не украшает обычные imports manifest-группами: это правильное ограничение для сторонних сервисов. Но website enrollment MosaicVPN ошибочно попадает именно в этот generic path. Поэтому текущая карточка «Импортированная подписка» — не проблема дизайна и не сбой API профиля; это доказательство потери provider identity между exchange и desktop daemon.

> **Принцип исправления:** `website enrollment` — отдельная команда домена provider, а не вариант ручного «Добавить URL».

### 2.2. Почему HTTP 400 нельзя сейчас чинить предметно

`POST /v1/connect` превращает ошибку `Manager.Connect()` в HTTP 400. Flutter не распаковывает `{ "error": "…" }`, поэтому пользователь видит только библиотечный DioException. Скриншот подтверждает транспортный статус, но не причину. Устанавливать конкретный диагноз по этой информации было бы гаданием.

### 2.3. Почему текущая таблица и bulk test не соответствуют требованиям

Стандартный Flutter `DataTable` автоматически измеряет ширины и показывает selection-checkboxes, если у строки есть selection handler. Это не пригодно для desktop-таблицы диагностики с десятками маршрутов и тем более для mobile.[1]

Существующий `/v1/servers/test-all` запускает до 16 probe параллельно, а затем возвращает только итоговый список. У него нет job ID, события прогресса, остановки, блокировки второго теста или distinction между public server и Smart Group. Поэтому косметическое изменение кнопки не даст требуемого поведения.

## 3. Предварительное исследование и архитектурные решения

### 3.1. Tunnel runtime

Для desktop sing-box рекомендует при TUN с `auto_route` настроить loop avoidance через `route.auto_detect_interface`, `route.default_interface` либо `outbound.bind_interface`; на Linux совместно с `auto_route` рекомендуется `auto_redirect`.[2] [3] Это будет baseline для проверки текущего generated config, а не автоматически включаемая замена.

Для Smart Group правильной runtime-моделью является provider-defined group, превращаемая daemon в один virtual route/outbound. Внутри группы допустим `urltest` со строго определёнными URL, interval и tolerance; `urltest` выбирает среди opaque outbound tags, не раскрывая их пользователю.[4] Это согласуется с требованием отображать Smart Group как обычный маршрут типа «Smart Group», но никогда не показывать private pool nodes.

Для VLESS в preflight должны быть проверены обязательные поля `server`, `server_port`, `uuid`, совместимые TLS/transport поля и отсутствие полей, не поддерживаемых bundled sing-box 1.13.18.[5] Ранее поле `encryption` уже было источником compatibility bug, поэтому новая проверка должна использовать фактический bundled binary, а не универсальную схему другой версии.

### 3.2. Таблица маршрутов

Не следует внедрять тяжёлый UI framework без решения по лицензии и mobile UX. `data_table_2` полезен как reference fixed header/width API, но сам не реализует ручной resize и reorder columns. Syncfusion DataGrid технически умеет resize и persisted widths, но потребует отдельного решения по dependency/license.[6] [7]

**Рекомендуемая реализация:** собственный `RouteGrid` на desktop с virtualized scroll layout и `RouteColumnSpec`, плюс отдельные compact `RouteCard` на телефоне. Это сохраняет контролируемый Mosaic visual language, не добавляет row-selection semantics и позволяет persist user preferences через SharedPreferences.

## 4. Подробный план работ

### Этап 0 — заморозить ложные статусы и собрать доказательства

1. Ввести тип `ConnectionFailure` в Flutter с полями `code`, `operation`, `message`, `retryable`, `correlationId` и `details`.
2. В `DaemonApi.connect`, `connectGroup`, `connectGroupCandidate` и Android facade распаковывать тело ошибок Dio. Пользователь видит, например, «Маршрут не найден», «Конфигурация не прошла проверку», «Не хватает системного разрешения»; полная diagnostic detail остаётся локально в журнале.
3. В daemon разделить коды: `route_not_found`, `empty_provider_routes`, `candidate_not_member`, `config_invalid`, `runtime_unavailable`, `runtime_start_failed`, `tun_permission_denied`, `dns_or_route_failure` и `upstream_connect_failed`. HTTP status сам по себе не должен быть единственным диагностическим контрактом.
4. До `Manager.Connect()` выполнять preflight: выбранный route существует, group принадлежит выбранной subscription, provider manifest version согласована, config build успешен, затем embedded `sing-box check -c` для desktop или native/libbox validation для Android.
5. Создать локальный sanitized diagnostic bundle: версия клиента/daemon/sing-box, OS/platform, tunnel mode, route type, provider manifest version, operation ID, validation result и последние 200 строк sing-box/daemon logs. Секреты URL, UUID, password, SNI и полные endpoints маскировать.
6. Добавить воспроизводимые integration tests: raw server connect; provider Smart Group connect; provider source без manifest; malformed VLESS; missing runtime; cancellation during connecting.

**Критерий выхода:** следующая неудачная попытка больше не показывает просто DioException. Она даёт конкретный safe code и локальный correlation ID; тесты подтверждают его для каждого класса.

### Этап 1 — правильный website enrollment и subscription-profile attachment

1. Добавить daemon endpoint `POST /v1/providers/enroll` (или эквивалентную provider command) с exchange payload: `provider_id`, `provider_account_id`, `subscription_name`, `subscription_url`, `session_token`/direct token только в encrypted local storage, не в обычном subscription JSON.
2. Этот endpoint обязан atomically: найти subscription по паре `(provider_id, provider_account_id)`; создать либо обновить именно provider source; выставить `hide_physical_nodes=true`; сохранить canonical display name; выполнить refresh manifest before returning success.
3. `AppShell._completeDesktopWebsiteEnrollment()` заменить: после redeem он вызывает provider enrollment endpoint, **не** `addSubscription`.
4. Сохранить idempotency: повторное нажатие сайта обновляет ту же подписку и не создаёт «MosaicVPN · Direct», duplicate import или другой кабинет.
5. В data model отделить:
   - `SubscriptionSource`: local, imported, provider;
   - `ProviderAttachment`: provider ID, account ID, capability document version, attachment status;
   - secret account material в `FlutterSecureStorage`/OS storage, а не в list rendering model.
6. После enrollment вызвать refresh и вернуть compound result: provider subscription, base profile availability, manifest group count, cabinet capability. UI success message должен сообщать точный результат, например: «MosaicVPN добавлен: 7 групп, кабинет подключён».
7. Для уже ошибочно созданной «Импортированной подписки» сделать migration: если URL canonical MosaicVPN и matching enrolled account найден, convert in-place to provider source. Не создавать вторую строку; при необходимости объединить duplicates с явным confirmation.

**Критерий выхода:** после website enrollment пользователь видит одну строку MosaicVPN, карточка открывает базовый профиль без login и полный кабинет после login; в инспекции subscription есть `source=provider`, `provider_id=mosaicvpn`, attachment account ID; legacy imported duplicate отсутствует.

### Этап 2 — довести manifest и Smart Groups до subscription-scoped production flow

1. В hosted provider manifest добавить explicit `manifest_version`, `provider_id`, `subscription_capabilities`, `groups[]`, group policy, disabled state и safe displayed aggregate metadata. Endpoint уже существует, но contract должен быть versioned и проверяться.
2. В `daemon.refresh()` provider enrollment обязан получить manifest, сохранить его `SaveManifestForSubscription(subscriptionID)`, собрать virtual Smart Group routes и установить `serverCount` как count user-visible routes, а не private nodes.
3. UI routes получает manifest **строго по selected `subscription_id`**, а не global `activeManifest`.
4. Каждая Smart Group отображается одной строкой: type `Smart Group`, title, description/badge, disabled status, current aggregate latency when measured. Ни host, ни IP, ни pool node name, ни raw VLESS URL не попадают в Flutter model, logs или clipboard.
5. Connect Smart Group только по `group_id`. Daemon внутри выбирает member/candidate. Browser/dashboard/routes не строят individual pool-node connection.
6. Дополнить tests матрицей: normal imported third-party subscription → no Mosaic decoration; Mosaic provider subscription → seven groups; two provider accounts → groups scoped to each subscription; disabled LTE placeholder → visible disabled row with no connect; no private candidate serialised in HTTP response.

**Критерий выхода:** внутри MosaicVPN subscription постоянно видны provider-declared groups, в том числе disabled placeholder «Свободный LTE», а тест snapshots подтверждает отсутствие private pool node fields в UI/API responses.

### Этап 3 — устранить фактическую причину туннелирования, а не маскировать ошибку

Этот этап начинается только с capture из Этапа 0. Возможные ветви устраняются по реальному `ConnectionFailure.code`.

| Наблюдаемая причина | Исправление | Проверка |
|---|---|---|
| `empty_provider_routes` | Сначала завершить этапы 1–2; connect button disabled до успешного manifest refresh. | Smart Group count > 0 перед connect. |
| `config_invalid` | Golden tests для generated JSON и `sing-box check`; adapter на bundled 1.13.18; reject unknown/removed fields. | Проверка config для VLESS Reality/TLS, Trojan, SS, Hysteria2 и group config. |
| `runtime_unavailable` | Проверить packaging sing-box, daemon discovery, version contract, app exit cleanup. | Fresh portable/Setup/DEB install reports runtime available. |
| `tun_permission_denied` | Явный capability/permission preflight: Windows elevation/WFP, Linux `cap_net_admin`, Android VpnService permission. | Controlled error and one-click remediation guidance. |
| `routing_loop_or_dns` | Сравнить generated config с TUN guidance: outbound default-interface binding/auto detection, DNS rules and loop avoidance. Linux route checks only with supported privileges. | DNS, TCP, UDP and reconnect smoke tests. |
| `upstream_connect_failed` | Показать safe failure class, preserve exact local sing-box log, re-check selected provider route via permitted test endpoint. | Known-good test profile and controlled failing fixture produce different codes. |

**Platform workstreams.**

- **Windows:** preflight daemon/runtime discovery; validate generated config with bundled executable; retain one process and WFP lifecycle; inspect route status and require admin only where the chosen TUN mode needs it. Configure default-NIC loop avoidance through sing-box supported routing fields, not custom proxy chaining.
- **Linux:** validate `cap_net_admin`, TUN device availability and packaged binary; only enable Linux-specific `auto_redirect` after detecting nftables support; guarantee disconnect cleanup and portable data isolation.
- **Android:** retain native `VpnService` as tunnel authority; do not duplicate desktop route mechanics; validate libbox config before `startAndAwaitReady`, forward native error/state to Flutter and protect service networking from self-capture according to platform contract.
- **All platforms:** dashboard and Routes use the same typed connect orchestration and same error mapping. No screen may mark a route «Активен» until daemon/native status confirms it.

**Критерий выхода:** fresh Windows Setup, Windows portable, Linux DEB, Linux portable and Android APK each pass: add provider → see groups → connect a Smart Group → DNS/TCP/UDP browse test → disconnect → exit/relaunch; failure fixtures return typed diagnostics, not generic HTTP 400.

### Этап 4 — Routes UI: нормальная desktop-grid и mobile presentation

1. Удалить row selection из route browsing. Использовать `showCheckboxColumn: false`; checkbox остаётся только в специальном multi-select action mode, если он появится отдельно.
2. Ввести persisted `RouteGridPreferences` per device: visible columns, pixel widths, sort key, sort direction, compact density. Сброс — «Стандартный вид».
3. Столбцы по умолчанию на desktop: **Тип**, **Название**, **Регион**, **Статус**, **Задержка**, **Джиттер**, **Потери**, **Скорость**, **Последняя проверка**. По умолчанию тип, название, статус и задержка видимы; остальные включаются context menu шапки.
4. В заголовке таблицы правый клик открывает одно menu: показ/скрытие каждого доступного столбца, compact/comfortable density, autosize visible columns, reset widths, reset layout. Минимально необходимый столбец «Название» нельзя скрыть.
5. Между header cells — drag handles. Desktop хранит user width; двойной клик возвращает autosize. Горизонтальный scroll и sticky header являются штатными, но table не должен быть горизонтальной «шторкой» на телефоне.
6. До фактической проверки latency/jitter/loss/speed выводить `—`; слово «Авто» разрешено только как selection policy Smart Group и никогда как измеренное значение ping.
7. Сортировка: левый клик header меняет ascending/descending; правый клик открывает column menu. `unknown` значения всегда идут после измеренных значений вне зависимости от направления, чтобы не смешивать отсутствие измерения с нулём.
8. На mobile вместо wide table использовать вертикальные Route Cards: type badge, название, статус и latency в первой строке; disclosure открывает подробности и действия. Ни одна критичная кнопка не зависит от горизонтального scrolling.
9. Row/group context menu: Connect, Test latency, Open subscription profile, copy/share link where allowed, refresh; Edit/Delete только mutable source. Для Smart Group нет действий, раскрывающих pool nodes.

**Критерий выхода:** на 360 px телефоне все действия доступны без горизонтальной прокрутки таблицы; на desktop пользователь меняет columns и widths, закрывает и вновь открывает приложение — layout сохраняется; checkbox не отображается в normal browsing mode.

### Этап 5 — единый отменяемый тест задержки

1. Добавить daemon-owned `LatencyTestJob` с job ID, owner subscription/group/route IDs, total, completed, status, cancellation context, started/finished timestamps и result summary.
2. API:
   - `POST /v1/latency-tests` создаёт job;
   - `GET /v1/latency-tests/{id}/events` отдаёт SSE `started`, `progress`, `route_result`, `finished`, `cancelled`, `failed`;
   - `POST /v1/latency-tests/{id}/cancel` запрашивает отмену;
   - `GET /v1/latency-tests/active` возвращает single active job.
3. Daemon допускает только одну активную пользовательскую проверку на installation. Все остальные `Test latency` disabled с tooltip «Сначала остановите или дождитесь текущей проверки». Повторный click запускает Stop only для owner job.
4. Для user-owned ordinary nodes тестируются visible routes. UI обновляет их строки по deterministically selected order с `completed/total`.
5. Для Smart Group тестируются daemon-side opaque candidates. UI показывает `Проверка маршрута: xx/xx` и только safe aggregate: current best, median latency, jitter/loss summary, available/unavailable. Candidate labels/endpoints не сериализуются.
6. Network measurements разделить семантически:
   - latency — TCP/HTTPS connect timing или controlled URL probe;
   - jitter — разброс нескольких latency samples одной цели;
   - loss — доля failed probes в finite sample;
   - speed — отдельный opt-in bounded download/upload test, не маскирующийся под ping.
7. После cancellation сохраняются уже законченные результаты с timestamp; непроверенные остаются `—`. Фоновый smart group URLTest и ручной test job не должны конкурировать за один и тот же selected outbound без explicit coordinator.

**Критерий выхода:** при тестировании группы/подписки пользователь видит живой progress `0/7 → 7/7`, результат каждой visible ordinary route или aggregate Smart Group, кнопку Stop и невозможность запустить второй test. После Stop daemon не продолжает создавать новые probe, а UI остаётся консистентным.

### Этап 6 — callback fallback page в стиле Mosaic

1. Оставить HTTPS fallback как исключительный путь для устройства, на котором Android App Link ещё не verified; основным остаётся direct App Link.
2. Заменить текущий standalone dark-card layout на tokens главного сайта: atlas paper palette, serif/sans hierarchy, Mosaic compass mark, тонкие border линии, нормальные button states и тот же mobile spacing.
3. Текст сделать кратким: «Открываем MosaicVPN», «Если приложение не открылось — нажмите кнопку». Никаких технических терминов, token/state, URL и маркетинговых рискованных формулировок.
4. Невалидный/expired callback показывает понятную recovery action «Вернуться в кабинет», не raw error.
5. Написать visual regression snapshots 360 px, 768 px и 1440 px; проверить dark/light browser controls and external-scheme fallback.

**Критерий выхода:** fallback выглядит как часть mosaic website, не как отдельный generic portal; всегда ясно, что сделать пользователю, и no callback secret is rendered.

## 5. Порядок реализации и release gates

| Волна | Работы | Обязательные проверки до merge/release |
|---|---|---|
| **A: correctness** | Этапы 0–2 | Go tests, daemon API contract tests, Flutter unit/widget tests, proof that provider subscription holds seven groups and no physical pool node fields. |
| **B: connection** | Этап 3 | Generated config fixtures, `sing-box check`, runtime/package validation, Linux sandbox smoke test, device/manual matrices for Windows and Android. |
| **C: interaction** | Этапы 4–5 | Golden/wide/mobile UI tests, test job cancellation and concurrency tests, SSE reconnection test, performance test on 100 route rows. |
| **D: finish** | Этап 6 | Visual screenshots and external App Link end-to-end test after signed Android release. |

Release запрещён, если выполняется хотя бы одно условие: website enrollment создаёт generic imported Mosaic source; provider subscription has zero manifest routes without explicit provider error; UI displays generic DioException; a private pool member is visible; a second latency job can start while first is active; route marked active before confirmed daemon/native connected state.

## 6. Матрица приёмки

| Сценарий | Windows | Linux | Android |
|---|---:|---:|---:|
| Website enrollment creates provider source + base profile | Required | Required | Required |
| Full cabinet attaches after website auth | Required | Required | Required |
| Seven provider Smart Groups render inside subscription | Required | Required | Required |
| Private pool nodes absent in UI/API | Required | Required | Required |
| Smart Group connection succeeds or returns typed diagnostic | Required | Required | Required |
| DNS/TCP/UDP tunnel smoke test | Physical host | Sandbox/physical host | Physical device |
| Routes table/cards usable at target viewport | Desktop | Desktop | 360/412 px |
| One live cancellable latency test | Required | Required | Required |
| Callback direct link + fallback | Required | Required | Physical device/browser |

## 7. Что уже доказано, а что ещё нельзя утверждать

Уже доказано, что current website enrollment loses provider metadata on the desktop path; что daemon provider-aware manifest flow exists; что generic imports intentionally do not receive Mosaic decoration; что existing bulk test lacks the requested job semantics; и что UI hides the HTTP 400 body.

Нельзя честно утверждать конкретную root cause туннеля до capture structured error и runtime logs на той платформе, где воспроизводится failure. Linux можно закрыть sandbox и package tests; Windows и Android потребуют final physical validation после implementation because actual TUN permission, WFP and VpnService behaviour depend on the target host/device.

## References

[1] [Flutter DataTable documentation](https://api.flutter.dev/flutter/material/DataTable-class.html)

[2] [sing-box TUN configuration](https://sing-box.sagernet.org/configuration/inbound/tun/)

[3] [sing-box Route configuration](https://sing-box.sagernet.org/configuration/route/)

[4] [sing-box URLTest outbound](https://sing-box.sagernet.org/configuration/outbound/urltest/)

[5] [sing-box VLESS outbound](https://sing-box.sagernet.org/configuration/outbound/vless/)

[6] [data_table_2 repository and limitations](https://github.com/maxim-saplin/data_table_2)

[7] [Syncfusion configurable/resizable Flutter DataGrid example](https://github.com/SyncfusionExamples/How-to-add-delete-and-resize-columns-in-Flutter-DataTable)

[8] [Throne desktop client reference](https://github.com/throneproj/Throne)

[9] [Exclave configuration compatibility reference](https://github.com/ExclaveNetwork/Exclave/wiki/Configuration)
