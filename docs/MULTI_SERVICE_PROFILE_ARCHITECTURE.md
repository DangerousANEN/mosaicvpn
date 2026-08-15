# MosaicVPN: единый мультисервисный профиль

## Назначение

Клиент должен поддерживать несколько независимых VPN-провайдеров без смешивания учётных записей, подписок или секретов. **MosaicVPN** является встроенным официальным провайдером; сторонний оператор может подключить свой сервис через открытый Provider Manifest и один из унифицированных способов входа.

Каждый профиль хранит только метаданные провайдера, режим авторизации, opaque access token и URL персональной конфигурации. Физические узлы защищённых групп остаются у оператора: клиент получает только итоговую конфигурацию либо выбранный маршрут, а не внутренний пул.

| Поле | Назначение | Пример |
|---|---|---|
| `profile_id` | локальный UUID профиля | `b31c…` |
| `provider_id` | устойчивый публичный идентификатор оператора | `ru.mosaicvpn` |
| `provider_url` | HTTPS-origin API/manifest оператора | `https://sub.zxc1x1.ru` |
| `display_name` | отображаемое название | `MosaicVPN` |
| `auth_method` | `pairing_code`, `password`, `subscription_url`, `oauth` | `pairing_code` |
| `access_token` | opaque token, scoped to клиенту | не отображается в UI |
| `session_token` | opaque токен кабинета, если требуется | не отображается в UI |
| `subscription_url` | персональный sing-box-compatible feed | `…/api/direct/singbox?token=…` |
| `active` | профиль, который обслуживает текущий runtime | `true` |

## Provider Manifest

Оператор публикует метаданные по адресу `GET /.well-known/mosaic-client.json` либо отдаёт их после аутентификации на указанном `manifest_url`. Manifest не является каналом передачи секретов.

```json
{
  "schema_version": 1,
  "provider_id": "ru.mosaicvpn",
  "display_name": "MosaicVPN",
  "api_base_url": "https://sub.zxc1x1.ru",
  "auth": {
    "pairing_code": {"endpoint": "/api/link/redeem", "code_length": 8},
    "password": {"endpoint": "/api/auth/login"}
  },
  "subscription": {"format": "sing-box", "token_endpoint": "/api/direct/singbox"},
  "capabilities": ["smart_groups", "account", "freeze", "subscription_link_rotation"]
}
```

Незнакомый `schema_version`, non-HTTPS endpoint или отсутствующий `provider_id` должны отклоняться. Клиент не должен выполнять код, загруженный из manifest, и не должен доверять логотипам/текстам manifest как инструкциям.

## Вход и привязка

Для MosaicVPN поддерживаются два равноправных входа.

| Сценарий | API | Результат |
|---|---|---|
| Код из Telegram `/link` | `POST /api/link/redeem {"code":"AB23CD45"}` | клиентский token и персональный direct feed |
| Email и пароль | `POST /api/auth/login {"email":"…","password":"…"}` | web token, client token и персональный direct feed |
| Регистрация на сайте | `POST /api/auth/register` | те же токены; Telegram может быть привязан из кабинета |
| Сторонний сервис | URL/QR-приглашение с `provider_id` и HTTPS endpoint | provider-specific token и feed по manifest |

> **Pairing-код всегда нормализуется к восьми символам алфавита `ABCDEFGHJKMNPQRSTUVWXYZ23456789`.** Пробелы и дефисы разрешены только как визуальные разделители и никогда не становятся частью отправляемого токена.

Поле кода в клиенте не содержит идентификатор Telegram. Оператор сопоставляет его на сервере, а в приложение возвращает только opaque client token. Пароли передаются исключительно по HTTPS и не записываются Flutter-приложением в логи, настройки или аналитику.

## Единый раздел «Профили и маршруты»

Разрозненные экраны **Stations**, **Subscriptions** и **Groups** заменяются единой точкой входа. Внутри выбранного профиля пользователь видит понятные разделы: «Умные маршруты», «Мои источники», «Избранное» и «Дополнительно». На мобильном устройстве технические операции по URL-подпискам и локальным proxy-listener показываются только в разделе «Дополнительно» и не занимают основную навигацию.

Основной dashboard хранит `selected_profile_id` и `selected_route_id`. При подключении runtime получает итоговый sing-box outbound для этого профиля. Для умной группы операторский API выбирает здоровый узел, а клиент устанавливает **прямое** соединение с отобранным узлом; сервисный VPS не является транзитным hop.

## Платформенный runtime

| Платформа | Источник конфигурации | Системная интеграция |
|---|---|---|
| Windows / Linux | локальный `mosaicd` и bundled `sing-box` | TUN либо local SOCKS/HTTP proxy |
| Android | тот же HTTPS profile contract, без `mosaicd` | `VpnService` + native sing-box runtime и Flutter MethodChannel |
| iOS / macOS | тот же HTTPS profile contract | Network Extension / platform runtime после отдельной реализации |

На Android отсутствие native runtime не может подменяться тестовым состоянием. Приложение обязано показать определённую ошибку готовности платформы и запретить кнопку «Подключить» до готовности `VpnService`.

## Хранение и выход

Токены профилей хранятся в защищённом platform storage. «Выйти» удаляет token, local runtime config и персональную подписку текущего профиля, затем останавливает tunnel. Выход из одного профиля не затрагивает другие профили. Смена языка, темы и режима tunnel должна сохраняться локально независимо от доступности удалённого account API; runtime-only параметры дополнительно передаются в daemon/native bridge с явно отображаемой ошибкой при неудаче.

## Критерии готовности

Релиз не должен содержать `MockDaemonApi` как production fallback и не должен показывать demo-маршруты, demo-подписки или тестовый административный аккаунт. Для каждого профиля должны быть покрыты тестами: нормализация pairing-кода, вход по email, logout, получение личной subscription URL, выбор smart route и запуск/остановка runtime на поддерживаемой платформе.
