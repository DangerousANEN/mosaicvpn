# План исправлений: подписки, кабинеты, подключение и веб-управление

**Статус:** проект плана для согласования до начала новой серии изменений.  
**Приоритет:** сначала устранить блокеры подключения и целостности данных; затем вернуть управление подпиской и админ-функции; регистрацию по логину/паролю реализовать как отдельный защищённый контур, а не как быстрый UI-патч.

## 1. Вывод по текущей проблеме

> Ошибка не сводится к одному неудачному deep link. В текущей реализации обычная подписка MosaicVPN была превращена в специальный, неудаляемый `provider`-источник, а Android-подключение Smart Group стало требовать сохранённый кабинетный токен. Это нарушает главное правило продукта: **подписка должна работать сама по себе, а кабинет только расширяет её возможностями**.

Текущий Android-фасад автоматически преобразует все ссылки `sub.zxc1x1.ru` в provider source, скрывает у него обычный URL-цикл и запрещает удалить основную строку. Кроме того, native TUN-конфигурация строится только из account session, а не из выбранной URL-подписки. Эти два решения объясняют невозможность удалить источник и сообщение «Сначала войдите в MosaicVPN». [1] [2]

Ниже приведён целевой контракт, а затем строгая последовательность работ. Она исключает риск снова создать одновременно несколько несогласованных представлений одной подписки.

## 2. Целевая модель данных и поведения

| Сущность | Хранение | Назначение | Может работать без входа в кабинет |
|---|---|---|---|
| **Подписка** | Локальное хранилище клиента / daemon store | Название, канонический URL, режим обновления, распарсенные маршруты, порядок отображения | **Да** |
| **Маршрут** | Производный от подписки | Обычный server profile или Smart Group, полученная из manifest совместимого сервиса | **Да** |
| **Привязка кабинета** | Локально и отдельно от подписки | `subscription_id`, provider ID, account ID, session/access material, capability flags, дата привязки | Нет, она не нужна для базового подключения |
| **Базовый профиль подписки** | Публичный capability endpoint, доступный по URL подписки | Срок, статус, трафик, лимит устройств; без платежей и личных данных | **Да** |
| **Расширенный кабинет** | Авторизованные API поставщика | Баланс, платежи, пополнение, устройства, заморозка, перевыпуск ссылки | Только после привязки |

### 2.1 Непереговорные правила

| Правило | Требуемое следствие |
|---|---|
| Ссылка подписки — основной объект | Сайт добавляет в клиент именно `https://sub.zxc1x1.ru/<opaque-id>` как обычную подписку, будто пользователь вставил её вручную. |
| Кабинет — надстройка | После добавления выполняется отдельная привязка профиля именно к ID этой локальной подписки. Она не создаёт вторую «MosaicVPN» строку. |
| Подключение независимо от кабинета | Выбранный URL и распарсенные маршруты достаточны для connect/TUN. Отсутствие session token может заблокировать только операции кабинета, а не VPN. |
| Удаление является локальным | «Удалить подписку» удаляет локальный URL, маршруты, Smart Groups state и cabinet binding. Сервис, баланс и удалённая подписка не отменяются. |
| Нет раскрытия внутреннего пула | Обычные маршруты, содержащиеся в пользовательской feed-подписке, могут быть распарсены как стандартные профили; private pool кандидатов Smart Group не передаётся и не отображается. |
| Несколько кабинетов поддерживаются | Каждая подписка имеет максимум одну текущую binding-запись; один клиент может иметь много подписок и привязок разных providers. |

### 2.2 Новая локальная запись `SubscriptionCabinetBinding`

```text
subscription_id            local stable subscription ID (foreign key, unique)
provider_id                e.g. mosaicvpn
provider_account_id        opaque provider account reference
provider_display_name      label for UI
session_secret_ref         keychain/secure-storage reference, never plaintext in list
client_access_secret_ref   optional secure-storage reference
capabilities_json          profile/payment/devices/freeze/link_rotate/app_link_code
attached_at / refreshed_at timestamps
```

Ни URL подписки, ни список её маршрутов не должны зависеть от этой записи. При удалении подписки binding удаляется атомарно вместе с зашифрованными/secure-storage секретами. При выходе из конкретного кабинета удаляется только binding/секреты, но не сама подписка.

## 3. Последовательность работ

### Этап P0 — Блокеры v0.3.22: подписка, delete, подключение и Android Logs

Этап P0 выполняется первым и выпускается как минимальный исправляющий релиз. Никакие изменения регистрации не смешиваются с ним.

| ID | Работа | Реализация | Критерий готовности |
|---|---|---|---|
| P0-1 | Убрать автоматическое превращение URL Mosaic в provider row | В `AndroidHostedDaemonApi` удалить `_asMosaicProviderSource` из `addSubscription` и миграции `listSubscriptions`; Android сохраняет URL без искусственного `source: provider`. На desktop daemon аналогично перестать заменять plain URL subscription provider-записью. | Ручной импорт и добавление с сайта создают обычный URL source с одним стабильным ID. |
| P0-2 | Реализовать delete как локальное удаление | Удалить hard-block для Mosaic ID на Android. Добавить одну транзакцию: удалить subscription, parsed routes/local cache, Smart Group cache/key namespace и binding + secrets. Desktop daemon: удалить subscription и его binding, не вызывать удалённый revoke. | Сайт-добавленная подписка удаляется с первого раза; при перезапуске не появляется снова; веб-кабинет и баланс не меняются. |
| P0-3 | Развязать VPN connect и кабинет | Android: `buildNativeTunConfig` получает выбранную Subscription/route и строит config из уже распарсенного share URI либо скачивает **эту** URL-подписку. Прямой account feed остаётся только как fallback, когда явный маршрут отсутствует. Desktop: connect выбирает subscription route, не `store.Account` как обязательное условие. | Свежий пользователь добавляет ссылку вручную и подключается, не выполняя вход в кабинет. |
| P0-4 | Smart Groups от manifest без provider-subscription row | При обнаружении `provider_id=mosaicvpn` по canonical URL/metadata получить manifest, но сохранять group state, связанный с обычным `subscription_id`. Private pool остаётся hidden. | Smart Groups видны под нужной URL-подпиской, не создают отдельный «MosaicVPN Direct»/provider source. |
| P0-5 | Нормальная ошибка подключения | Разделить ошибки: URL fetch/parse, unsupported URI, Android permission, native runtime, invalid config, route unavailable. Показывать код, человеческий текст и действие («Откройте разрешение VPN», «Обновите подписку»), не «сначала войдите». | Индуцированный сбой не показывает ошибочный login gate и не отмечает маршрут активным. |
| P0-6 | Исправить Logs toolbar на телефоне | Заменить единый `Row` на adaptive layout: заголовок и filter в первой строке, Auto как видимый icon button, Copy/Save/Clear в `PopupMenuButton` на compact width. Минимальная ширина целей 44 dp. | На 360, 393 и 432 dp нет обрезанных кнопок; все действия доступны. |
| P0-7 | Устранить старые миграционные призраки | Одноразовая migration помечает legacy provider rows, ищет совпадающую URL-подписку, переносит binding; если URL не найден — создаёт URL subscription с сохранением имени и canonical URL. Перед изменением создаётся backup local store. | После обновления нет дубликатов, а важные ссылки и привязки не теряются. |

### Этап P1 — Привязка кабинета к уже добавленной подписке

| ID | Работа | Реализация | Критерий готовности |
|---|---|---|---|
| P1-1 | Новый API attach вместо enrollment-as-subscription | Ввести `POST /v1/subscriptions/{id}/cabinet/attach` и `DELETE /v1/subscriptions/{id}/cabinet`. Payload привязки содержит провайдер, account reference и временные access artifacts; daemon/Android сохраняет только binding. | API не создаёт и не переименовывает подписку, возвращает состояние binding/capabilities. |
| P1-2 | Website flow «Добавить в MosaicVPN» | Сайт сначала выдаёт одноразовый auth artifact, содержащий canonical subscription URL и account binding. Клиент по callback: находит подписку по canonical URL; при отсутствии — добавляет URL; затем attach к её ID. | Один клик создаёт ровно одну URL-подписку и привязывает к ней кабинет. |
| P1-3 | Ручной код профиля | В `SubscriptionCabinetScreen` добавить явный блок **«Подключить кабинет»** с двумя действиями: **«Войти на сайте»** и **«Ввести код»**. Код вводится в приложении, normalise/validate 8 символов, отправляется на attach redeem endpoint. | Пользователь может привязать кабинет без deep link; после успеха UI переключается на расширенный кабинет. |
| P1-4 | Генератор кода на сайте | В кабинете показать кнопку «Получить код для приложения». Код одноразовый, действует 10 минут, повторная генерация отзывает предыдущий неиспользованный. Под ним: время истечения, copy, понятная инструкция. Использовать тот же серверный ledger, что и Telegram `/link`, но с origin `web`. | Код, выданный на сайте, проходит через тот же redeem endpoint, что и Telegram-code. |
| P1-5 | Визуальная привязка к конкретной подписке | В заголовке профиля показывать название и сокращённую URL-подписку; dialog attach предупреждает, к какой подписке привяжется кабинет. Если binding уже есть — показывать provider и «Переподключить/Отключить кабинет». | Невозможно незаметно привязать кабинет к неверной подписке. |
| P1-6 | Deep-link fallback | Оставить verified HTTPS App Link и `mosaic://` fallback как ускоренный транспорт, но они должны вызывать тот же attach service. Fallback page показывает кодовый путь, если приложение не открылось. | Deep link и manual code дают одинаковое финальное состояние. |
| P1-7 | Привязка и аккаунты нескольких провайдеров | Все вызовы unified cabinet provider-scoped: выбранная subscription ID определяет token reference и endpoint adapter; никаких глобальных `MosaicAccountService.instance` для кабинета другой подписки. | Две подписки разных providers могут иметь отдельные кабинеты, не перезаписывают друг друга. |

### Этап P2 — Восстановить полный веб-кабинет подписки

Backend уже содержит защищённые server-side действия freeze/unfreeze и rotate link, но `cabinet.html` их не выводит. [3] [4]

| ID | Функция сайта | Детали реализации | Критерий готовности |
|---|---|---|---|
| P2-1 | Показать ссылку подписки | Вывести `subscription_url` в отдельном, не обрезающемся блоке с Copy и предупреждением «не передавайте ссылку посторонним». Никакой ссылка не должна попадать в analytics/log text. | Пользователь видит текущую ссылку в профиле и копирует её одним действием. |
| P2-2 | Заморозка / возобновление | Добавить action card, серверные `POST /api/account/freeze` и `/unfreeze`, явное подтверждение, reload profile после результата. | Статус обновляется без перезахода; повторяемая команда безопасна. |
| P2-3 | Перевыпуск ссылки | Добавить кнопку «Перевыпустить ссылку», показывать irreversible warning; после серверного подтверждения обновить URL; явно предупредить, что прежняя ссылка перестанет действовать. | Новый URL отображён и копируется; действие фиксируется в audit log. |
| P2-4 | Устройства и usage | Подключить уже возвращаемые `devices`, `traffic_*`, lifetime traffic и next charge; UI для управления устройствами добавлять только после проверки безопасных provider endpoints. | В кабинете видны реальные устройства и метрики, а не статический placeholder. |
| P2-5 | Payments/top-up | Оставить 10 / 30 / custom; перед переходом показывать выбранную сумму и итоговые дни; после callback/webhook обновлять history. | Оплата открывает URL платёжного провайдера, кабинет показывает pending/paid. |
| P2-6 | Связь с приложением | В card «Добавить в приложение» добавить две равноценных опции: открыть приложение и показать код. Сначала pre-issue artifact, но по клику сразу выполняется навигация без лишнего второго клика. | Нет зависшего «Готовим…» и нет скрытого пути входа. |

### Этап P3 — Регистрация с логином/паролем и восстановление пароля

Эта работа требует отдельной security review и миграции базы. Нельзя помещать обычный пароль в текущую `users`-таблицу или переиспользовать Telegram ID как парольную идентичность.

| Компонент | Проектное решение |
|---|---|
| Идентичность | Ввести immutable `account_id` (UUID/ULID) и таблицу `account_credentials`; Telegram ID становится optional verified identity link, а не первичным ключом человека. Existing Telegram users получают migration-linked account. |
| Логин | Логин или e-mail должны быть уникальны case-insensitively. После password verification сервер выдаёт opaque, HttpOnly, Secure, SameSite session cookie либо обменный token только для app callback. |
| Пароль | Хранить только adaptive password hash, например Argon2id с серверной pepper из env. Не логировать, не включать в JSON errors, не передавать клиенту повторно. |
| Регистрация | `POST /api/auth/register`: нормализация логина/e-mail, проверка rate limit, hash password, создание account, verification challenge. До подтверждения e-mail/Telegram ограничить чувствительные операции. |
| Восстановление | `POST /api/auth/password-reset/request` всегда отвечает одинаково; токен хранить только в hash-форме, single-use, max 15 min; `POST /confirm` меняет password и инвалидирует все session tokens. |
| Verification delivery | Нужен подтверждённый SMTP/transational-email provider. Если почтовая отправка ещё не подключена, не заявлять работу восстановления: сначала подготовить домен, DKIM/SPF/DMARC и secret configuration. Telegram можно оставить альтернативным каналом для уже связанного аккаунта. |
| Brute force / abuse | Per-IP + per-account rate limit, uniform error, delayed response and structured security audit log. CAPTCHA — только при подозрительной активности, не как штатный путь. |
| Account linking | В кабинете: «Привязать Telegram» / «Привязать e-mail». Запрещать тихое объединение учётных записей; нужен challenge с обеих сторон и audit event. |

### Этап P4 — Восстановить и расширить админку

В текущей web admin панели есть только индивидуальное начисление и audit history. Bot command `/broadcast` сохранился, но не имеет web endpoint/UI. [5] [6]

| ID | Функция | Безопасная реализация | Критерий готовности |
|---|---|---|---|
| P4-1 | Единая серверная RBAC-проверка | Убрать расхождение `ADMIN_IDS` и `admins.txt`; один server-side authorization provider. Любой endpoint повторно проверяет роль по server session. | Нельзя получить admin API только благодаря UI/URL. |
| P4-2 | Broadcast composer | Web API создаёт draft, рассчитывает получателей, требует preview и explicit confirmation, затем помещает рассылку в persistent job queue. Сообщения отправляются rate-limited; есть cancel до старта и результат delivered/failed. | В админке доступны preview, аудит, прогресс и итог; повтор не создаёт дубликат. |
| P4-3 | Цена и тарифы | Конфигурация `pricing_plans` в БД: amount, days, enabled, display order, effective-at, actor, reason. Website/bot читают только активную версию. Изменение требует preview и audit. | Изменение цены применяется к новым счетам, не меняет уже созданные invoices. |
| P4-4 | Индивидуальное начисление | Сохранить существующий idempotent ledger, но включить в общий audit stream. | Весь текущий функционал остаётся работать. |
| P4-5 | Массовая выдача баланса | Фильтры аудитории, dry-run с числом получателей, max batch, reason, scheduled/confirmed execution, idempotency key per account. Запрещены необратимые «всем» одной кнопкой без preview. | Админ видит список/количество, подтверждает и получает итоговый audit report. |
| P4-6 | Наблюдаемость | Admin audit events для price/broadcast/credit/freeze/link rotate. Редактируемый экспорт CSV — после access control review. | Любое управляющее действие имеет actor, time, parameters, status и request ID. |

### Этап P5 — Полная регрессия и выпуск

| Блок | Автоматические проверки | Обязательный ручной smoke |
|---|---|---|
| Subscription lifecycle | Unit/integration: add, canonicalize, duplicate prevention, attach, detach, delete, restart migration | Добавить URL вручную, через сайт и через code; удалить каждый сценарий; проверить, что серверный аккаунт не изменился. |
| Connection | Fixture feed → parse → Android config/desktop config; test no session present; config validation | Подключение Windows + Android без cabinet binding; затем с binding; отказ VPN permission; отключение. |
| Smart Groups | Manifest scoped by `subscription_id`, no candidates/private pool in route list; group connect test | Smart Groups внутри одной подписки, live test `xx/xx`, cancel, no secondary group test. |
| Cabinet attach | One-time code: valid/expired/used/wrong subscription; deep-link path uses same service | Получить код на сайте, ввести в приложении; проверить exact subscription binding, detaching, second provider. |
| Website cabinet | Endpoint tests freeze/unfreeze/rotate plus no secret in HTML/browser console | Отобразить, copy и rotate subscription URL; freeze/resume; payment history refresh. |
| Password auth | Registration, duplicate detection, reset generic response, token expiry/use, session invalidation, rate limit | Создать новый тестовый account, подтвердить identity, reset password, login, link Telegram. |
| Admin | RBAC denial, broadcast preview/idempotency, price effective dates, bulk credit dry-run | Открыть admin with normal user (denied) and admin (features), complete one safe test broadcast to test audience. |

## 4. Предлагаемый порядок релизов

| Release | Содержание | Условие выпуска |
|---|---|---|
| **v0.3.23 hotfix** | P0: URL-first subscription lifecycle, delete, connection without cabinet, log toolbar, migrations, typed errors | Проходит Windows + Android smoke на физическом устройстве. |
| **v0.3.24** | P1 + P2: per-subscription cabinet binding, website/code attach, explicit site controls and subscription URL | Проходят manual-code, deep-link, rotate and freeze regression cases. |
| **v0.3.25** | P4: restored admin broadcast/price/bulk-credit with authorization/audit | Security review и protected test audience. |
| **v0.4.0** | P3: login/password, registration, recovery, migration from Telegram-first accounts | Threat model, email delivery validation and security review complete. |

## 5. Решения, которые нужно подтвердить перед реализацией

| Вопрос | Рекомендация |
|---|---|
| Логин для сайта | Использовать **e-mail + пароль** как основной password flow; отдельный public username оставить только как display/login alias после verified e-mail. |
| Восстановление | Через verified e-mail; Telegram — fallback исключительно для заранее привязанных Telegram-аккаунтов. |
| Код профиля | 8 символов, single-use, 10 минут, new code revokes earlier unused one, одинаковый API для сайта и Telegram. |
| Удаление Mosaic subscription | Только локальное, с подтверждением, без revoke remote link или billing cancellation. |
| Ссылка на профиль сайта | Отображать текущий subscription URL только авторизованному владельцу; base-profile endpoint URL не раскрывает сам URL в ответе. |
| Массовое начисление | Выполнять через persistent job + dry-run + audit, не синхронным HTTP loop. |

## 6. Приёмочные критерии, по которым можно начинать следующий этап

Начинать P0 следует сразу. Перед P3 необходимы подтверждённый delivery-provider для электронных писем и решение о canonical identifier. Критерий успешного завершения P0: пользователь на чистом Android или Windows устанавливает приложение, добавляет URL `sub.zxc1x1.ru` вручную либо с сайта, видит её как обычную подписку, видит Smart Groups в ней, подключается без логина в кабинет, может удалить источник локально и не видит обрезанных controls в Logs.

## References

[1]: https://github.com/DangerousANEN/mosaicvpn/blob/main/flutter/lib/core/api/android_hosted_daemon_api.dart "Android subscription storage and provider normalization"
[2]: https://github.com/DangerousANEN/mosaicvpn/blob/main/flutter/lib/core/services/android_mosaic_account_service.dart "Android account service and native TUN config"
[3]: https://github.com/DangerousANEN/mosaicvpn/blob/main/site/cabinet.html "MosaicVPN website cabinet"
[4]: https://github.com/DangerousANEN/mosaicvpn/blob/main/bot/bot.py "Website cabinet, billing and app authorization handlers"
[5]: https://github.com/DangerousANEN/mosaicvpn/blob/main/site/admin.html "MosaicVPN web administration UI"
[6]: https://github.com/DangerousANEN/mosaicvpn/blob/main/internal/api/account_handlers.go "Daemon provider enrollment and link code lifecycle"
