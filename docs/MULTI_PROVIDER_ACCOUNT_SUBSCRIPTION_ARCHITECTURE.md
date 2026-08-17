# MosaicVPN: модель мультипровайдерских аккаунтов и подписок

## Решение в одном абзаце

Клиенту не нужно «склеивать» все VPN-сервисы в один удалённый аккаунт. Правильная модель состоит из двух уровней: **Mosaic Identity** объединяет способы входа в собственный сервис MosaicVPN — сайт, Telegram и приложения, — а **Service Profile** представляет отдельную учётную запись у конкретного VPN-провайдера. Один пользователь может иметь профиль `MosaicVPN · личный`, профиль другого оператора для работы и несколько локальных коллекций ссылок. Между ними не смешиваются токены, биллинг, устройства, маршруты и данные поддержки.

> **Аккаунт — это отношение пользователя к оператору. Подписка — это источник маршрутов. URL подписки никогда не является аккаунтом и не должен использоваться как глобальный идентификатор пользователя.**

Такое разделение сохраняет требование о Smart Groups: у каждого provider-профиля есть управляемый каталог маршрутов, внутри которого Smart Groups показываются обычными строками. Отдельной записи `MosaicVPN Direct` нет; физические узлы закрытого пула не выводятся в интерфейс.

## Что уже есть и что пока смешано

В текущем daemon state уже существуют `ProviderAccounts`, provider-specific manifests и поля `provider_id` / `provider_account_id` у подписки. Это хорошая основа. Однако legacy `State.Account` хранит один singleton Mosaic account, Android синтезирует фиксированный `provider-mosaicvpn-primary`, а bot/web session всё ещё привязана к `telegram_id`. В результате один и тот же объект одновременно означает человека, аккаунт MosaicVPN, его токен, provider subscription и текущий каталог маршрутов.

| Слой | Уже реализовано | Ограничение, которое надо убрать |
|---|---|---|
| Provider manifest | Manifest отдельный для provider subscription; Smart Groups и private pool policy описываются провайдером | Manifest пока адресуется не устойчивым service profile, а косвенно через один provider subscription |
| Subscription | Есть `source`, `provider_id`, `provider_account_id`, `hide_physical_nodes` | `local` объединяет внешнюю ссылку и локальную коллекцию; у Android один provider ID захардкожен |
| Учётная запись | Website-first code, Telegram code и session token работают для MosaicVPN | Единственный `Account` в desktop state и `telegram_id` как фактический owner key |
| UI | Smart Groups находятся внутри provider subscription; локальные URL можно добавлять | Нет верхнего понятного объекта «профиль сервиса», поэтому provider account и subscription смешиваются |

## Целевая предметная модель

### 1. Mosaic Identity — только для собственных сервисов MosaicVPN

**Mosaic Identity** — серверный UUID пользователя MosaicVPN. Он не обязан существовать для использования внешней ссылки или стороннего провайдера. К нему привязываются способы входа: Telegram, подтверждённый email/password, будущий passkey и website-first session.

| Поле | Назначение |
|---|---|
| `mosaic_account_id` | Неизменяемый внутренний UUID пользователя MosaicVPN |
| `identities[]` | Привязки `telegram`, `email`, `passkey`; одна identity может быть отвязана без удаления аккаунта |
| `created_at`, `locale`, `security_state` | Общие server-side настройки и аудит |
| `device_sessions[]` | Сессии сайта и приложений, с возможностью отзыва конкретного устройства |

Для существующих пользователей выполняется безопасная миграция `telegram_id → mosaic_account_id`: создаётся одна Mosaic Identity на каждую текущую запись, а Telegram становится её identity. Все счета, дни доступа, реферальные связи и текущий `short_uuid` сохраняют связь с новым `mosaic_account_id`.

### 2. Service Profile — отдельный аккаунт у конкретного провайдера

**Service Profile** — главный объект в приложении. Это не URL и не Smart Group, а локальная запись о том, что пользователь авторизован у оператора. Профиль поддерживает несколько аккаунтов даже у одного provider: например, личный и рабочий.

```text
ServiceProfile
  profile_id              локальный случайный UUID
  provider_id             стабильный ID оператора, например ru.mosaicvpn
  issuer_origin           https://sub.zxc1x1.ru
  remote_subject_id       opaque ID пользователя у этого оператора
  display_name            «MosaicVPN · личный»
  auth_method             website_oauth | pairing_code | password | invitation
  credential_ref          ссылка на секрет в OS keystore, не сам токен
  capabilities            account, freeze, billing, devices, smart_groups …
  status                  active | expired | frozen | needs_reauth | error
  primary_catalog_id      provider-managed каталог маршрутов
  last_sync_at, last_error
```

`profile_id` создаётся на устройстве и не передаётся между операторами. `remote_subject_id` возвращает сам оператор после авторизации и используется только для обнаружения смены/отзыва его сессии. Поэтому один профиль внешнего сервиса не позволяет этому сервису узнать об аккаунтах пользователя у других операторов.

### 3. Connection Catalog — источник маршрутов, а не пользователь

Вместо одного неоднозначного `Subscription` вводится концептуальное разделение `ConnectionCatalog` и его `kind`.

| Kind | Владелец | Можно удалить/переименовать | Биллинг и устройства | Что показывает UI |
|---|---|---:|---:|---|
| `provider_managed` | Service Profile | Нет, только logout профиля | Да, только в контексте данного провайдера | Smart Groups и разрешённые провайдером обычные маршруты |
| `external_link` | Пользователь устройства | Да | Нет | Импортированные пользователем VLESS/Trojan/подписки |
| `local_collection` | Пользователь устройства | Да | Нет | Вручную добавленные маршруты и сборники |
| `provider_shared` | Service Profile | По политике провайдера | Только если capability заявлена | Публичные/корпоративные каталоги оператора |

У `provider_managed` каталога есть `profile_id`, provider manifest и защищённая ссылка/credential, но она никогда не показывается в полном виде, не попадает в логи и не является доступной для drag-and-drop в «Мои источники». У внешнего URL нет `profile_id` по умолчанию: это независимый локальный источник, а не безымянный аккаунт.

### 4. Route Reference — точный выбор для dashboard/runtime

Dashboard хранит не строковый `server_id`, а ссылку на маршрут:

```text
RouteReference
  profile_id?             null для локальной/внешней коллекции
  catalog_id
  route_id
  route_kind              smart_group | direct_node | local_node
```

Это снимает нынешнюю проблему двух способов выбора маршрута. Сначала пользователь выбирает **сервисный профиль или локальный источник**, затем один маршрут. Для Smart Group `route_id` — ID группы из manifest; client получает только нужный provider feed/candidate shard и соединяется с выбранным узлом напрямую. Закрытый pool не становится частью UI state.

## Безопасность и границы доверия

| Правило | Практический смысл |
|---|---|
| Токены по профилям | `session`, `direct feed`, refresh tokens и секреты хранятся отдельно в Keychain/Keystore/secret service, по ключу `profile_id`; в обычном daemon JSON остаётся только `credential_ref` |
| Никакой авторизации по URL | Link subscription разрешает подключение, но не даёт права управлять балансом, устройствами, freeze или link rotation |
| Верификация provider manifest | Только HTTPS, фиксированный `provider_id`, origin binding, schema validation, разумные лимиты и явное подтверждение пользователем перед входом |
| Website-first auth | В callback передаётся исключительно short-lived one-time code + state/PKCE; browser session и subscription token не оказываются в URI |
| Capability gating | UI показывает «Заморозить», «Пополнить», «Устройства» и «Перевыпустить ссылку» только когда выбранный provider profile официально заявил capability |
| Удаление профиля | Logout удаляет токены, provider-managed catalogs и runtime configuration **только данного** `profile_id`; локальные коллекции и другие профили остаются |
| Смена/ротация URL | Ротация затрагивает один provider-managed catalog. Старый URL признаётся недействительным провайдером, новый защищённо сохраняется в том же профиле |

Особенно важно не пытаться автоматически «превратить» произвольную URL-подписку в аккаунт. Клиент может предложить кнопку «Войти в сервис» только если пользователь явно запросил discovery, manifest верифицирован, а provider origin совпадает с invite/URL origin. В противном случае это всего лишь внешний источник маршрутов.

## Как это выглядит для пользователя

### Dashboard

Вверху появляется компактный селектор **«Сервис»**, например `MosaicVPN · личный`. Ниже ровно один селектор **«Маршрут»**: Smart Group «Минимальный пинг», «Германия», «Максимальная стабильность» либо разрешённый обычный маршрут. Переключение профиля меняет доступный каталог маршрутов, но не удаляет выборы в других профилях. Локальная коллекция может быть выбрана как источник подключения, однако её отсутствие не делает кабинет провайдера недоступным.

### Раздел «Профили и маршруты»

Это единая точка вместо конкурирующих сущностей «Stations», «Subscriptions» и «Groups».

| Раздел | Содержимое |
|---|---|
| `Сервисы` | Карточки `MosaicVPN · личный`, `Provider B · рабочий`, состояние, кнопка «Добавить сервис» |
| `Маршруты сервиса` | Provider-managed catalog выбранного профиля: Smart Groups — обычные строки с типом «Smart Group»; private pool rows отсутствуют |
| `Мои источники` | Внешние ссылки и локальные коллекции; доступны добавление из буфера, файла, вручную, rename/reorder/delete |
| `Аккаунт` | Контекстно выбранный service profile: баланс, freeze, платежи, устройства, support, ротация link — только если provider capabilities это поддерживают |

### Добавление

Пользователь нажимает одну кнопку **«Добавить»**, затем осознанно выбирает один из двух разных сценариев:

1. **«Добавить сервис»** — сканирует QR/вставляет HTTPS invitation; приложение загружает и проверяет manifest, показывает название оператора и доступные способы входа, затем создаёт Service Profile.
2. **«Добавить источник»** — вставляет subscription URL, share URI, набор строк или файл; приложение предлагает добавить в существующую локальную коллекцию либо создать новую. Никакого ложного обещания «личного кабинета» для этой ссылки нет.

Для MosaicVPN primary path остаётся «Войти через сайт». После возврата создаётся или обновляется именно `ServiceProfile(provider_id: ru.mosaicvpn)`, а не отдельная видимая `MosaicVPN Direct` подписка.

## API-контракт для универсального клиента

Provider manifest должен быть discovery-документом, а не исполняемым контентом. Предлагаемый минимум:

```json
{
  "schema_version": 1,
  "provider_id": "ru.mosaicvpn",
  "display_name": "MosaicVPN",
  "issuer_origin": "https://sub.zxc1x1.ru",
  "auth": {
    "website_authorization": {"start_url": "/cabinet.html", "redirect_scheme": "mosaicvpn"},
    "pairing_code": {"endpoint": "/api/link/redeem", "length": 8}
  },
  "catalog": {"manifest_endpoint": "/api/client/manifest", "feed_endpoint": "/api/direct/singbox"},
  "capabilities": ["smart_groups", "account", "billing", "freeze", "devices", "subscription_link_rotation"]
}
```

После аутентификации клиент получает provider-scoped opaque credential и bootstrap response с `remote_subject_id`, профилем, catalog descriptors, manifest version и capabilities. Внешний provider никогда не получает Mosaic Identity, Telegram ID или сведения об иных профилях. Для MosaicVPN бот и кабинет должны перейти с технической привязки к `telegram_id` на `mosaic_account_id`, однако старые коды `/link` продолжают работать как один из способов подтвердить identity.

## Поэтапная миграция

| Этап | Изменение | Совместимость |
|---|---|---|
| 0. Инвентаризация | Добавить тестовые fixtures: один Mosaic profile, два разных providers, два профиля у одного provider, внешняя ссылка и local collection | Никакого изменения user data |
| 1. Server identity | Создать `mosaic_accounts` и `account_identities`; backfill current Telegram users 1:1; web/app sessions ссылаются на `mosaic_account_id` | Старые Telegram code/session принимаются и разрешаются через mapping |
| 2. Client state v4 | Заменить singleton `State.Account` на `ServiceProfiles[]`; сохранить legacy reader и автоматически создать `MosaicVPN · основной` profile | `mosaicvpn-default` мигрирует в новый UUID profile, текущая feed ссылка сохраняется |
| 3. Catalog split | Явно ввести `provider_managed`, `external_link`, `local_collection`; manifests key `profile_id + catalog_id` | Existing `source=provider` → `provider_managed`, `source=local` → `external_link` или `local_collection` по наличию URL |
| 4. UI | Dashboard получает service selector; Routes screen получает сервисные каталоги и «Мои источники»; Account становится profile-scoped | Последний рабочий `RouteReference` переносится; если profile удалён, fallback на другой доступный маршрут |
| 5. Provider contract | Добавить bootstrap/discovery endpoint, capability validation и profile-specific token refresh | MosaicVPN поддерживает новый contract первым; сторонние providers подключаются постепенно |
| 6. Security hardening | Secrets удаляются из plain daemon state; реализуются device/session revoke и per-profile logout | Миграция запрашивает повторный login только если secret transfer невозможен |

## Что не следует делать

Не стоит добавлять в 8-символьный Telegram код «ID сервиса». Это делает код длиннее, но не решает задачу: пользователь должен сначала выбрать сервис или открыть verified invite, а код остаётся credential-подтверждением уже известного provider context. Также не следует общим списком смешивать Smart Groups, внешние ссылки и аккаунты: базовому пользователю это будет выглядеть как три разных способа подключиться.

Не стоит хранить несколько provider tokens в одной `Account` записи, не стоит показывать закрытые pool nodes как обычные server rows и не стоит использовать subscription URL как видимый primary ID. Эти решения приведут к утечкам, ошибочной ротации чужой ссылки и невозможности нормального logout одного сервиса.

## Рекомендуемое решение для старта

Нужно утвердить именно эту иерархию:

```text
Mosaic Identity (только MosaicVPN)
└── Service Profiles (MosaicVPN personal, Provider B work, …)
    └── Connection Catalogs (provider-managed / external / local)
        └── Routes (Smart Group / ordinary server / local server)
```

Первая практическая реализация должна мигрировать один текущий MosaicVPN profile в новую модель, а затем заменить Android hard-code `provider-mosaicvpn-primary` на динамический список `ServiceProfile`. После этого «Добавить сервис» можно открыть для manifest-compatible операторов, не меняя привычный поток Telegram/website login для MosaicVPN.

Это даст пользователю единый и понятный клиент, но сохранит техническую и security-изоляцию каждого VPN-провайдера.
