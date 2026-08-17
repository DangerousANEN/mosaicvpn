# Исследование Throne и Exclave для MosaicVPN v0.3.18

**Дата:** 18 августа 2026 г.  
**Цель:** найти инженерные и UX-паттерны для устранения сбоя подключения на всех подписках, перевода приложения к модели «подписка → подключённый профиль/кабинет» и повышения надёжности VPN-рантайма.

## Лицензионная граница

> Throne и Exclave публикуют исследованные файлы под GNU GPLv3. Их исходный код нельзя копировать в проприетарные части MosaicVPN без соблюдения условий GPL. Ниже зафиксированы только независимые архитектурные выводы; реализация MosaicVPN должна быть написана заново, с собственными именами, тестами и API-контрактами.

## Подтверждённые выводы

| Область | Наблюдение в reference-проектах | Применение в MosaicVPN |
|---|---|---|
| Модель данных | Throne хранит профиль отдельно от группы и прикрепляет его к группе через `gid`; добавление профиля обновляет и сам профиль, и список профилей группы в согласованной операции. [1] | `Subscription` остаётся первичным контейнером. Новый `SubscriptionProfileLink` должен существовать независимо от самой подписки и прикрепляться по `subscriptionId`; вход в аккаунт не может неявно создавать глобальную подписку. |
| Старт туннеля на desktop | Throne сериализует start/stop, проверяет готовность core перед стартом, строит конфигурацию до запуска, устанавливает «Connecting» только на время операции и переводит в рабочее состояние лишь после подтверждённого результата RPC. [2] | MosaicVPN должен создать единый `ConnectionCoordinator`: один mutex/очередь на переключение, validate → stop old → build → start → await-ready → commit state. Успех маршрута нельзя отражать до реальной готовности sing-box. |
| Ошибки TUN/DNS | Throne классифицирует ошибки конфигурации, strict routing и TUN, сохраняя первопричину и предлагая только уместное восстановление. [2] | Убрать общий текст «Не удалось изменить подключение». Возвращать типизированные ошибки `permissionDenied`, `unsupportedRoute`, `configInvalid`, `tunEstablishFailed`, `runtimeExited`, `subscriptionUnavailable` с локализованной рекомендацией. |
| Android VPN lifecycle | Exclave сначала получает разрешение VPN, строит `VpnService.Builder`, задаёт адреса, маршруты, DNS и правила приложений, затем вызывает `establish()` и передаёт FD в core; при остановке освобождает resolver, core, TUN FD, слушатель сети и статистику. [3] | В MosaicVPN сохранить и усилить существующую native state-machine: Android route action всегда должен проходить через один Android runtime adapter, разрешение → config validation → start foreground service → poll terminal state. После любой ошибки требуется атомарный cleanup и сохранённая диагностика. |
| Смена сети Android | Exclave отслеживает underlying network и передаёт изменения в VPN, не смешивая это с UI-вызовами. [3] | Добавить отдельный native network-change path и наблюдаемое событие для Flutter. Это снизит зависания и ложное «Connected» при Wi‑Fi ↔ LTE. Не включать без device-level regression tests. |
| Разбор конфигураций | Exclave принимает поддерживаемые типы, проверяет обязательные поля, валидирует зависимости transport/TLS/Reality/flow и отклоняет неподдерживаемые варианты вместо частично валидной конфигурации. [4] | Расширить MosaicVPN parser contract: результат `Parsed`, `Unsupported(reason)`, `Malformed(reason)`. Не строить TUN-config из частично распарсенного URI; отображать профиль в списке с объяснением, но не показывать действие Connect как доступное. |
| Smart groups | В Throne рейтинг выбирается до построения конфигурации, а UI не должен блокироваться измерениями. [2] | Для MosaicVPN Smart Group остаётся одной строкой маршрута без раскрытия private-pool nodes. Клиент получает только provider-manifest с политикой, локально ранжирует допустимые кандидаты и формирует final config до старта. |

## Точное объяснение текущего блокирующего сбоя

В `GroupsScreen._connect()` используется desktop-oriented `DaemonApi.connect()` или `connectGroup()`. На Android `AndroidHostedDaemonApi` наследует недоступные реализации этих методов, поэтому действие завершается `UnsupportedError` до native VPN runtime. Это не дефект сети, не проблема Remnawave и не «скрытая» ошибка. Исправление должно устранить неверный путь вызова, а не скрыть исключение.

## Целевая архитектура подключения

```text
Route row / Dashboard
        ↓
ConnectionCoordinator.connect(SubscriptionRouteRef)
        ↓
resolve subscription + route capabilities
        ↓
[desktop] DaemonRuntimeAdapter    [Android] AndroidTunRuntimeAdapter
        ↓                                  ↓
build config → sing-box API       permission → native config → await-ready
        ↓                                  ↓
RuntimeResult(connected | typed error) ← shared contract
        ↓
UI status + activity log + route state
```

## Целевая архитектура кабинетов

```text
Subscription (always exists first)
   ├─ Route source / manifest / imported profile
   └─ optional SubscriptionProfileLink
          ├─ provider id + account id
          ├─ secure session/token reference
          ├─ capability snapshot (cabinet, billing, devices, link rotation)
          └─ cached profile summary + refresh timestamp
```

`AccountsScreen` не является общим кабинетом. Это индекс ссылок `SubscriptionProfileLink`: каждая карточка ведёт в конкретный кабинет подписки. Кабинет открывается также из контекстного меню соответствующей подписки.

## Обязательный набор действий контекстного меню

Для каждой подписки следует строить capability-based menu, а не разделять логику по `isProviderSource`:

| Действие | Доступность |
|---|---|
| Обновить | есть URL/manifest source |
| Копировать ссылку | есть исходная subscription URL |
| Открыть в браузере | URL использует http/https |
| Редактировать | локальная/импортированная подписка, не managed provider source |
| Удалить | локальная/импортированная подписка; managed source только после явного unlink |
| Поделиться | есть exportable source URL |
| Открыть профиль подписки | всегда; без link открывает базовую сводку и действие «Подключить кабинет» |

## Порядок реализации

1. Ввести `ConnectionCoordinator` и Android implementation для `connect()`/`connectGroup()`; написать regression tests, reproducing the prior `UnsupportedError`.
2. Сделать `SubscriptionProfileLink` и миграцию legacy global Mosaic account в ссылку на `provider-mosaicvpn-primary`, не создавая новую подписку на входе.
3. Удалить singleton `AccountScreen` из primary navigation; заменить на `AccountsScreen`, полностью убрать `ProviderProfileScreen` как параллельный global surface.
4. Переписать subscription context menu на capability-based action model и добавить generic `SubscriptionCabinetScreen`.
5. Ввести stale-while-revalidate cache профиля: immediate cached render, один coalesced refresh, явные TTL/error states.
6. Добавить website «Добавить в приложение»: one-time enrollment code + state + deep link, создающий подписку и link одной транзакцией.
7. Выполнить parser/connection regression matrix для VLESS, Trojan, VMess, Shadowsocks и Smart Group на Linux/Android emulator.

## References

[1]: https://github.com/throneproj/Throne/blob/stable/src/database/ProfilesRepo.cpp "Throne — ProfilesRepo.cpp"
[2]: https://github.com/throneproj/Throne/blob/stable/src/ui/mainWindow/mainwindow_profile_lifecycle.cpp "Throne — mainwindow_profile_lifecycle.cpp"
[3]: https://github.com/ExclaveNetwork/Exclave/blob/dev/app/src/main/java/io/nekohasekai/sagernet/bg/VpnService.kt "Exclave — VpnService.kt"
[4]: https://github.com/ExclaveNetwork/Exclave/blob/dev/app/src/main/java/io/nekohasekai/sagernet/group/SingBoxJSONParser.kt "Exclave — SingBoxJSONParser.kt"
