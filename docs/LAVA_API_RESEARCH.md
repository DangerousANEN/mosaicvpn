# Lava Business API findings

Источник: [Lava Business API](https://developer.lava.ru/), версия документации 2.1.0, проверено 16 августа 2026.

## Подтверждённые правила

Production base URL: `https://api.lava.ru/business`.

Каждый запрос к API использует raw JSON body и заголовок `Signature`. Подпись исходящего запроса — lowercase hex HMAC-SHA256 от байтов ровно той JSON-строки, которая отправляется, с использованием secret key проекта. Нельзя менять порядок полей, пробелы или экранирование после вычисления подписи.

Для входящих webhook применяется дополнительный ключ, а не secret key. Входящий callback должен сравнивать его `Signature` с HMAC-SHA256 от неизменённого raw HTTP body на additional key.

Основные требования к запросам: `Accept: application/json`, `Content-Type: application/json`, raw JSON body. Успешный ответ обычно содержит `data`, `status: 200`, `status_check: true`; ошибки содержат `error`.

## Invoice flow

Создание счёта: `POST /business/invoice/create` с `sum`, уникальным `orderId`, `shopId`, описанием и URL callback/success/fail. Полученную payment URL нужно открыть пользователю.

Финальный статус нельзя считать подтверждённым только по redirect на `successUrl`; необходимо принять проверенный webhook или запросить статус счёта через `POST /business/invoice/status`.

В MosaicVPN планируется два магазина и два webhook path:

- Site store: `https://sub.zxc1x1.ru/api/billing/lava/webhook/site`.
- Telegram store: `https://sub.zxc1x1.ru/api/billing/lava/webhook/bot`.

Success/fail URLs: `https://sub.zxc1x1.ru/cabinet.html?payment=success` и `https://sub.zxc1x1.ru/cabinet.html?payment=failed`.

## Security constraints

Credentials хранятся только в VPS environment, не в Git, frontend, URL, logs или callback payload. Для duplicate webhook используется atomic transition invoice `pending -> paid`. Сайт передаёт backend только session token и сумму; Lava secret keys в браузер не попадают.
