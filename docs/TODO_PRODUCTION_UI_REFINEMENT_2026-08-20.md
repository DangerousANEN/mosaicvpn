# Точечная доработка production-интерфейса MosaicVPN

- [x] Зафиксировать текущую production-версию и определить исходные файлы сайта и кабинета.
- [x] Проверить типографику и проблемные карточки профиля и пополнения на desktop и mobile.
- [x] Улучшить только шрифтовую иерархию, карточки профиля и пополнения, не меняя текущий стиль MosaicVPN.
- [x] Выполнить проверку существующих функций кабинета и подготовить изменения к публикации.

> Изменения подготовлены в исходниках. Публикация на VPS не выполнялась: доступ по SSH отсутствует после обязательного удаления временного ключа в предыдущей сессии.

## Публикация на VPS

- [x] Подготовить временную SSH-сессию с правами только на публикацию сайта.
- [x] Скопировать проверенный `site/cabinet.html` в production-каталог и проверить конфигурацию веб-сервера.
- [x] Проверить live-версию кабинета и удалить временный SSH-ключ.

Production-файл `cabinet.html` опубликован с совпадающей контрольной суммой. Live-проверка `https://sub.zxc1x1.ru/cabinet.html` подтвердила обновлённый текст блока собственной суммы. Временный SSH-ключ удалён локально после проверки.

## Точечная корректировка подписей Telegram

- [x] Убрать случайное подчёркивание у названия Telegram-бота в карточке пополнения.
- [x] Не выводить пользователю технический псевдоним `@tg_<id>`; оставить нейтральное название профиля и ID аккаунта.
- [ ] Проверить исправления локально и опубликовать их на VPS с последующим удалением временного ключа.

На приложенной карточке подтверждён браузерный underline ссылки: он распространялся на весь якорный элемент оплаты через Telegram. Исправление задаёт `text-decoration:none` именно этой карточке и переименовывает её из «В боте» в «В Telegram». На втором скриншоте подтверждён технический формат `@tg_831992162`; заголовок профиля теперь всегда нейтральный «Аккаунт MosaicVPN», тогда как ID продолжает оставаться отдельным копируемым полем для поддержки.

Локальный mobile-рендер подтверждает корректный заголовок «Аккаунт MosaicVPN» и отдельное отображение ID без технического Telegram-псевдонима. CSS-проверка подтверждает, что Telegram-карточка теперь не наследует подчёркивание ссылки.

## Windows-клиент и маршруты: новая диагностика

- [ ] Воспроизвести и локализовать HTTP 409 при добавлении подписки и профиля с сайта в Windows-клиент.
- [ ] Сверить единый источник подписок для Dashboard и вкладки «Маршруты», включая добавление и удаление.
- [ ] Показать обычные маршруты и Smart Groups в одной модели; добавить префикс `[SG]` Smart Groups и корректный тип маршрута.
- [ ] Добавить страну/флаг, полнострочный клик, hover/pressed/active-состояния и контекстное меню маршрута.
- [ ] Найти первопричину ошибки «Не удалось изменить подключение» и подтвердить исправление тестами.
- [ ] Безопасно опубликовать проверенные изменения на VPS и удалить временный ключ.

### Подтверждённые факты диагностики

1. Production access-log показывает успешный `POST /api/app-auth/exchange` и повторный `409` с тем же endpoint через 10 секунд. Это подтверждает повторную обработку одного одноразового enrollment callback в Windows-клиенте, а не ошибку выдачи кода сервером.
2. Dashboard создаёт синтетическую Mosaic-подписку из глобального manifest, если в локальном списке нет `isProviderSource`; вкладка «Маршруты» показывает только реально сохранённые источники. Из-за этого один и тот же клиент видит разное число подписок.
3. Provider manifest на VPS сейчас содержит Smart Groups без обязательного префикса `[SG]`. Источник должен маркировать эти названия сам, а не полагаться на hard-code в UI.
4. Для Mosaic source физические узлы остаются скрытыми по политике `HidePhysicalNodes`; это защита приватного пула. Обычные серверы должны быть видны только внутри обычных, пользовательских URL-подписок и локальных сборников.

### Целевой единый контракт

1. Dashboard и «Маршруты» используют один и тот же фактический список `subscriptionsProvider`; запрещены синтетические Mosaic-строки.
2. Mosaic URL-подписка определяется единообразно по каноническому HTTPS URL. Для неё оба экрана получают manifest строго с `subscription_id`, а не глобальный compatibility manifest.
3. В Mosaic URL-подписке видны только серверно-объявленные Smart Groups с префиксом `[SG]`; физические ноды пула не отображаются. В обычных URL-подписках и локальных сборниках видны их обычные серверы.
4. Одноразовый enrollment callback получает локальный ключ дедупликации `code + state`. Успешно погашенный callback больше не отправляется в exchange API и не создаёт ложный `409`.
5. Активный маршрут имеет отдельный `active_group_id` в daemon status. Поэтому запуск из Dashboard и «Маршрутов» выделяет одну и ту же Smart Group, не раскрывая выбранную физическую ноду.
6. В desktop-таблице все ячейки строки используют одинаковые hover/press/selected состояния. Первый основной клик выбирает маршрут; повторный клик запускает подключение. Вторичный клик в любой ячейке открывает контекстное меню. Колонка страны показывает только подтверждённую географию обычных серверов; для Smart Groups выводится нейтральное `—`.

### Выполнено 2026-08-20

- Подтверждена и устранена локальная причина ложного `409`: production access-log показал `200`, а затем повторный `409` обмена того же одноразового callback через 10 секунд. Desktop-клиент теперь игнорирует повторную доставку уже успешно обработанного `code + state`.
- Dashboard больше не создаёт synthetic Mosaic source и запрашивает manifest выбранной сохранённой Mosaic URL-подписки с `subscription_id`. Это устраняет расхождение количества подписок с вкладкой «Маршруты» и передаёт в Smart Group selector scoped ID, существующий в daemon.
- Provider manifest опубликован: все Smart Groups получили серверный префикс `[SG]`.
- Таблица маршрутов получила колонку страны для подтверждённых данных обычных серверов, active Smart Group status, выбор первым кликом, подключение повторным кликом, визуальные hover/press/selected состояния и контекстные операции маршрута.
- Пройдены: `go test ./internal/api ./internal/state ./internal/subs ./internal/store ./internal/proto`; весь Flutter test suite (71 тест); Flutter analysis; Linux release build. Live manifest и кабинет проверены после публикации; временный SSH-ключ удалён.

### Ограничение проверки артефакта Windows

Исходный код Windows-клиента исправлен и проверен Flutter-анализом, но Linux-среда не может собрать или прогнать Windows desktop runtime. Для выпуска обновлённого `.exe`/Setup нужен Windows build-host либо отдельный релизный процесс; до этого пользовательская Windows-установка останется на предыдущем бинарнике.

### Публикация обновлённого клиента

- [ ] Восстановить прежний workflow сборки Windows Setup и portable из истории репозитория.
- [ ] Собрать и проверить актуальные Windows, Linux и Android артефакты с исправлениями enrollment и маршрутов.
- [ ] Опубликовать release assets и обновить ссылки загрузки на production-сайте.
- [ ] Проверить live-загрузки, опубликовать контрольные суммы и удалить временный ключ VPS.

### Production-site polish

- [x] Проверить CSS-отступы и заменить ключевые локальные произвольные значения на согласованную 6/12-px сетку.
- [x] Переработать действия «Пауза» и «Перевыпустить ссылку»: иконки, понятные пояснения, подтверждения и безопасная цветовая семантика.
- [x] Проверить favicon во всех HTML entry points и исправить абсолютные пути к актуальному значку.
- [x] Опубликовать и проверить обновлённый production-сайт после завершения release-сборки.

#### Локальная visual-проверка 2026-08-20

- Desktop: сетка 6/12 сохраняет ритм карточек; действия доступа отделены по смыслу и показывают последствия до подтверждения.
- Mobile: основной аккаунт, показатели и кнопка добавления приложения сохраняют читаемую иерархию на ширине 390 px; действия доступа остаются отдельным следующем блоком без горизонтального переполнения.
- Live: v0.3.27-ссылки, встроенный favicon и панель подтверждения опубликованы; контрольные суммы HTML на VPS совпали с локальными. Встроенный favicon заменил внешний SVG-путь после ответа 502 на `/favicon.svg`.

### Telegram linking follow-up

- [x] Заменить текстовую кнопку копирования кода на icon-only действие с tooltip и корректным aria-label.
- [x] Сбалансировать карточки приложения и Telegram, чтобы левая карточка не выглядела пустой при выданном Telegram-коде.
- [x] Автоматически обновлять статус привязки Telegram после возврата во вкладку и до подтверждения связи сервером.
- [x] Проверить и опубликовать исправление Telegram-linking в production.

#### Локальная проверка Telegram-linking 2026-08-20

- Desktop и mobile: общая иерархия кабинета и ранние карточки сохраняют читаемость; визуальная фикстура содержит одновременно выданные коды приложения и Telegram.
- Копирование кода теперь доступно через отдельную иконку с tooltip/aria-label; текстовая подпись не конкурирует с самим кодом.
- Live: кабинет опубликован и подтверждён; после выдачи кода состояние проверяется сразу, при возврате во вкладку и каждые 4 секунды до подтверждённой привязки.

### Header cabinet action

- [x] Проверить варианты production-шапки и её mobile-поведение.
- [x] Выделить кабинет отдельным компактным действием с иконкой, не меняя общий язык навигации.
- [x] Проверить шапку на desktop/mobile и опубликовать исправление на VPS.

#### Локальная проверка header 2026-08-20

- Desktop: действие «Кабинет» заметнее базовых ссылок, но остаётся в пределах Atlas-палитры и не конкурирует с брендом.
- Mobile: иконка и подпись кабинета помещаются в компактной шапке без горизонтального переполнения.
- Live: главная и кабинет опубликованы; контрольные суммы совпали с локальными, временный SSH-ключ удалён после проверки.

### Mosaic manifest route audit

- [x] Получить текущий live-manifest выданной Mosaic-подписки и составить инвентарь маршрутов.
- [x] Сопоставить manifest с server-side настройкой Smart Groups и обычных серверов, а также с фильтрацией клиента.
- [x] Сообщить полный список, принцип выбора и подтверждённую причину отсутствия ожидаемого обычного сервера.

#### Manifest audit 2026-08-20

- Live `/api/manifest.json` выдаёт только 7 provider-defined Smart Group rows; обычных server/profile rows в payload нет.
- Клиент намеренно подавляет physical server rows под Mosaic-source (`!_isMosaicSubscription(source)`), поэтому даже импортированный обычный сервер не будет показан в этой подписке.
- Все активные группы используют `pool_id=mosaicvpn`; географические подписи пока не подкреплены отдельным pool/фильтром в manifest. `Максимальная скорость` несёт speed weight, но speed probe в live policy отключён.

### Smart Group route model completion

- [x] Инвентаризировать eligible candidate pools и подтверждённые геоданные на production-сервере.
- [x] Описать версионируемый manifest-контракт: Smart Group policy, подтверждённые гео-ограничения и отдельный публичный direct route.
- [x] Реализовать server-side выдачу кандидатов с реальными geo-фильтрами, bounded speed probe и безопасный public direct route без раскрытия private pool.
- [x] Обновить Windows/Linux/Android клиент: показать public direct route рядом с Smart Groups и честные состояния групп.
- [x] Прогнать backend и Flutter-тесты, включая speed selection, manifest parsing и подключение.
- [x] Собрать и опубликовать новый кроссплатформенный релиз, обновить сайт и production backend.
- [x] Подготовить итоговый список маршрутов и smoke checklist для Windows и Android.

#### Production inventory decision 2026-08-21

- В user-facing Remnawave feed подтверждён только активный публичный немецкий node/host set. Поэтому manifest объявляет `[SG] Германия` и отдельный `Mosaic Direct · Германия` с `country_code=DE`; CA и RU не публикуются как маршруты.
- Отдельные внешние записи Mosaic node inventory не считаются operator-controlled public route и не используются ни как Smart Group pool, ни как direct route.
- `[SG] Максимальная скорость` запускает проверку только после явного подключения: максимум два кандидата последовательно, по 2 MiB download/upload HTTPS-пробе, с лимитом 12 секунд. Провайдером endpoint является Cloudflare; Ookla не используется.

#### Release v0.3.28 — опубликован и проверен 2026-08-21

- GitHub release содержит Windows Setup и Portable, Linux DEB и Portable, а также подписанный Android APK. Все три GitHub Actions jobs завершились успешно.
- Backend manifest опубликован и live-проверен: `auto-speed` содержит ограничение в два 2 MiB HTTPS-теста, `[SG] Германия` имеет `country_code=DE`, а `direct_routes` содержит один `direct-de` VLESS маршрут. Зарезервированная compatibility-группа сохранена отключённой.
- Главная страница опубликована с пятью ссылками v0.3.28. Каждая ссылка и её целевой GitHub asset вернули HTTP 200 при проверке.
- Временные SSH-ключи удалены локально после каждой отдельной production-сессии.

### Next: public feed simplification and route UX

- [x] Сверить фактический публичный subscription feed с target-контрактом: один прямой public server для обычных клиентов; Smart Groups только как client-side virtual routes MosaicVPN.
- [x] Убрать из выдачи сторонних клиентов server-side pool/proxy rows и любые старые Smart Group ссылки, не раскрывая private pool members.
- [x] Сохранить в MosaicVPN один direct route плюс Smart Groups, которые выбирают кандидатов только локальным daemon/client runtime.
- [x] Сделать hover/press/selected состояние строк в таблице «Маршруты» единым для всей строки, а не отдельной ячейки.
- [x] Ограничить или адаптивно скрывать колонки таблицы, чтобы они не уходили за границу small desktop/mobile экранов.
- [x] Заменить стандартный dropdown подписок на branded selector и переработать выбор маршрута в dashboard в более понятный компактный интерфейс.
- [x] Прогнать Go/Flutter tests, собрать и опубликовать новый cross-platform release, затем проверить feed, сайт и временный SSH-ключ удалить.

#### Production inventory 2026-08-21

- Public subscription сейчас содержит 13 опубликованных host profiles: `/direct`, семь country routes и пять legacy server-side pool/proxy routes. Целевым остаётся только `/direct`.
- Production collector хранит отдельные direct candidate profiles и регулярно выполняет ограниченную TCP/proxy-проверку через sing-box. В pool groups есть свежие usable candidates для all, Germany, Canada, min-latency, max-speed и stable; legacy `owned` group пустая.
- Эти collector candidates не должны попадать в обычный subscription feed. Следующая реализация должна передавать их только локальному daemon MosaicVPN как scoped opaque candidate feed, а затем выполнять выбор и failover на устройстве пользователя.

#### Release v0.3.29 — опубликован и проверен 2026-08-21

- В Remnawave отключены 12 legacy host profiles. Обычная публичная subscription link теперь выдаёт ровно один VLESS profile с transport path `/direct`; закрытый backup таблицы `hosts` создан на VPS до изменения.
- Backend добавляет доступный только локальному daemon `GET /api/client-candidates/{opaque-subscription-id}`. Он возвращает максимум 80 свежих, успешно proxy-проверенных кандидатов в sing-box формате, без вывода их в обычный subscription response или UI-маршруты.
- MosaicVPN резолвит Smart Groups только по marker `mosaic_client_candidate`; direct virtual route разрешается исключительно к non-candidate profile с `direct_path=/direct`. Live-проверка подтвердила 31 bounded daemon-only candidate profiles и один ordinary public route.
- Таблица Routes теперь обрабатывает select/hover/press на уровне `DataRow`; на ограниченной ширине secondary telemetry-колонки временно скрываются, а name/action остаются видимыми. Предпочтения колонок сохраняются для широкого окна.
- Dashboard получил branded dialog selectors для subscription и route choice вместо стандартного `DropdownButtonFormField` и нижней шторки. Новый interaction smoke-test проверяет оба dialog flow.
- Пройдены `go test ./...`, весь Flutter suite (73 теста), Flutter analysis и локальная Linux portable+DEB сборка. GitHub release v0.3.29 содержит Windows Setup/Portable, Linux DEB/Portable и signed Android APK; все три release jobs завершились успешно.
- Production backend и landing page опубликованы. Live landing page содержит все пять v0.3.29 asset links, а каждый GitHub download URL вернул HTTP 200. Временный SSH-ключ удалён после проверки.

#### Android incident and Release v0.3.30 — опубликован и проверен 2026-08-21

- Санитизированный production inventory подтвердил: scoped candidate endpoint возвращает 74 свежих proxy-проверенных candidates с явными opaque group memberships; обычная subscription link остаётся с одним `/direct` VLESS route. Логи sing-box показывают регулярные URLTest/proxy attempts и удаление недоступных upstream candidates из eligible set по `proxy_ok`/freshness policy.
- Скриншот Android локализовал две client-side причины: `_scopeManifest()` не переносил `direct_routes`, а Android Smart Group connect ошибочно загружал обычную xHTTP direct subscription вместо scoped candidate feed. Поэтому телефон показывал только Smart Groups, а runtime получал неподдерживаемый `xhttp` transport.
- Android теперь сохраняет direct routes при subscription scoping; direct row соединяется только с единственным public profile, тогда как Smart Group скачивает отдельный `/api/client-candidates/{opaque-id}` payload и выбирает только кандидатов своей opaque group membership.
- Android builder нормализует legacy XHTTP label в sing-box HTTP transport и удаляет xHTTP-only fields перед передачей config в libbox. Это предотвращает observed `unknown transport type: xhttp` без включения кандидатов в user-visible subscription response.
- Добавлены targeted xHTTP/direct and scoped-candidate regression tests. Пройдены `go test ./...`, Flutter suite (75 тестов), Flutter analysis, локальная Linux portable+DEB сборка и три GitHub release jobs. GitHub release v0.3.30 содержит Windows Setup/Portable, Linux DEB/Portable и signed Android APK.
- Backend и download page обновлены live: candidate feed имеет explicit group IDs, manifest содержит direct route, а landing page и все пять v0.3.30 asset URLs проверены. SSH-ключ сохранён по явному указанию владельца для дальнейшей диагностики.

## Результаты визуальной проверки

Локальный desktop- и mobile-рендер страницы входа подтвердил, что обновлённая пара шрифтов сохраняет действующий Atlas-стиль: тёплая сетка, засечковые заголовки, моноширинные служебные метки и терракотовый акцент остаются без изменений. На ширине 390 px заголовок, описание, поля и кнопка не выходят за границы экрана. Карточки профиля и пополнения остаются скрытыми до авторизации; их DOM-идентификаторы и встроенный JavaScript дополнительно прошли синтаксическую проверку.

Локальная визуальная фикстура с тестовыми значениями подтвердила структуру после авторизации: карточка профиля сохраняет имя, идентификатор и срок доступа как единую запись, а показатели баланса, тарифа и трафика читаются как одна связанная полоса. На mobile карточка корректно переходит в одноколоночную композицию без переполнения текста.
