# MosaicVPN — подтверждённые дефекты и направление исправления

Дата: 2026-08-15

## Скриншоты и пользовательские наблюдения

| Симптом | Подтверждённая причина / риск | Направление исправления |
|---|---|---|
| Android «Не удалось загрузить группы», `Future<dynamic>` не является `Future<ProviderManifest>` | Экран `GroupsScreen` использует самостоятельный `groupsManifestProvider`, который всегда вызывает desktop daemon API и не использует Android-aware `mosaicManifestProvider`. | Удалить параллельный provider; использовать единый строго типизированный `mosaicManifestProvider` и безопасное сообщение без внутренней диагностики. |
| Android «Cabinet unavailable», HTTP 502 | `UnifiedAccountPanel` безусловно вызывает `daemonApiProvider.getUnifiedAccount()`, хотя Android не использует loopback daemon. | Сделать Android account path прямым и session-aware; не запрашивать desktop daemon на Android и не показывать сырые DioException пользователю. |
| В Routes светлая тема | `GroupsScreen` обращается к статическим `AtlasTheme.*` цветам вместо `ThemeColors.of(context)`. | Перевести экран и вложенные компоненты на активную палитру темы. |
| Внутренний pool виден пользователю | `GroupsScreen` рендерит `serversProvider`, health names и адреса сервера. Для Mosaic direct это может раскрыть внутренние ноды. | Для Mosaic subscription показывать только provider groups; для сторонних пользовательских подписок показывать отдельные импортированные ноды, сгруппированные по источнику. |
| Ложная отметка «Активен» | UI выводит active ID без строгого состояния connected и запрос группы выбирает сервер раньше подтверждённого запуска runtime. | Показывать статус только при `state == connected`; инвалидировать status/маршруты после фактического результата подключения. |
| Ошибка подключения 400 | Требует проверки payload /v1/connect, daemon resolver и реального sing-box config/runtime. | Добавить структурированную обработку API ошибок, диагностический контекст без секретов и e2e fixture для connect state machine. |
| daemon offline при запущенном mosaicd | Требует сверки lockfile paths/format, health endpoint и packaged runtime version. | Ввести согласованный discovery contract и отображать ошибку обнаружения вместо ложного offline. |
| Версия 0.1.0 | Runtime/daemon version берётся из устаревшей build default вместо package version. | Передавать release version в Go ldflags/package metadata и отображать app + daemon версии согласованно. |
| Шторки и системные scrollbars | Bottom sheet использует системный scrollbar и недостаточную высоту/desktop adaption. | Использовать тематизированный `Scrollbar`/`RawScrollbar`, adaptive route picker и table layout для desktop. |
| Нет настроек close-to-tray и полного выхода | Tray и WindowListener есть, но не доведены до persistent settings/явных команд. | Добавить `minimizeToTray` preference, контролируемый close dialog, tray submenu с connect/disconnect/open dashboard/routes/quit. |
| Языки и настройки неполны | Строки на экранах маршрутов/настроек захардкожены; некоторые layout constraints допускают по-буквенное сжатие. | Вынести строки в AppStrings RU/EN, применять локаль ко всем экранам и задать корректные flex/overflow constraints на mobile. |

## Референсы

Throne используется как ориентир полноты protocol/subscription/runtime возможностей, Exclave — как ориентир Android group/subscription/routing модели. MosaicVPN не копирует их UX: главная цель — безопасный dashboard для базовых пользователей с расширенными функциями только в «Ещё».

## Принцип приватности пула

Физические ноды внутреннего пула MosaicVPN не являются пользовательскими объектами и не должны попасть в UI, логи, ошибки, manifest, node health, таблицы либо названия активных маршрутов. Клиент получает только provider-defined smart groups, а сервер/direct-feed runtime выбирает физический выход внутри этой группы.
