# MosaicVPN v0.3.11 — pre-release review

**Статус отчёта:** 15 августа 2026. Этот документ отражает самостоятельную Linux-проверку после v0.3.10 и до создания следующего patch release.

> **Вывод:** v0.3.11 содержит подтверждённые исправления desktop runtime, но не должен рекламироваться как полностью верифицированный релиз до реальной проверки production account, физического Android и TUN-capable Linux/Windows host.

## 1. Исправления, подтверждённые в изолированном Linux-контуре

| Направление | Подтверждённое изменение | Проверка |
|---|---|---|
| Proxy listeners | `socks_addr` и `http_addr` теперь определяют реальные listener ports при старте sing-box. | Сохранённые `127.0.0.1:1080` и `127.0.0.1:1081` появились в `ss`; `/v1/status` вернул те же `proxy_socks` и `proxy_http`. |
| DNS | DNS URL вида `udp://77.88.8.8` и `https://1.1.1.1/dns-query` преобразуются в корректную sing-box DNS schema. | Proxy runtime стартовал, HTTP listener принял запрос. |
| Subscription isolation | Обычные сторонние feeds больше не получают синтетические Mosaic smart-groups; manifest сохраняется активным только для `mosaic-direct`. | Go regression tests для parser и API проходят. |
| Daemon health | Аутентифицированный loopback status корректно показывает `agent_connected: true`. | Подтверждено через `/v1/status`. |
| Daemon version | Linux/Windows packaging paths и GitHub release workflow передают tag version через `-X main.Version`. | Isolated daemon, собранный как `0.3.11`, вернул `daemon_version: "0.3.11"`. |
| Controlled link error | Неверный Telegram pairing code возвращает понятную локальную ошибку, а не неструктурированный transport exception. | Для malformed code получен HTTP 400: `pairing code must contain 8 valid symbols`. |
| Graceful shutdown | Authenticated shutdown останавливает daemon и дочерний sing-box. | После proxy connect оба процесса отсутствовали; orphan sing-box не найден. |
| Flutter quality gate | Account checkout panel приведён к lint-clean control flow. | `flutter analyze` завершился без issues; `flutter test` прошёл полностью. |
| Android release naming | Workflow больше не называет новый signed APK «Technical Preview». | Имена artifact/release attachment изменены на `MosaicVPN-Android-v*.apk`. |

## 2. Проверки, выполненные в этом контуре

| Проверка | Результат | Граница результата |
|---|---|---|
| `go test ./...` | Успешно. | Автоматические backend tests не заменяют production node E2E. |
| `flutter analyze` | Успешно, без issues. | Не подтверждает native platform runtime. |
| `flutter test` | Успешно: 50 tests. | Desktop tray/real OS window manager не подменяются widget tests. |
| Proxy connect | HTTP 200 при connect; state `connected`; sing-box и listeners запущены. | Fixture VLESS upstream не предоставлял рабочий внешний egress, поэтому HTTP proxy запрос завершился 502 на upstream. |
| TUN start | Конфигурация дошла до sing-box; ошибка корректно отдана в API. | Sandbox не содержит `/dev/net/tun`, поэтому реальный TUN не мог быть создан: это ограничение среды, а не доказательство неисправности пакета. |
| Daemon shutdown | Успешно. | Проверялся API путь shutdown; native tray interaction требует живую desktop session. |

## 3. Оставшиеся блокеры перед рекомендацией пользователям

| Приоритет | Блокер | Почему не закрыт | Нужная проверка |
|---|---|---|---|
| **P0** | Production account/login/manifest/group connect | Тесты не используют реальную тестовую подписку или допустимый одноразовый код. | С разрешённой тестовой учётной записью: login → manifest → smart group → direct external IP/DNS/traffic → disconnect. |
| **P0** | TUN на Windows/Linux target host | Текущий Linux sandbox не предоставляет `/dev/net/tun`. | Установить Linux DEB на чистую систему с `CAP_NET_ADMIN`; проверить TUN routes, kill switch, reconnect и cleanup. Повторить на Windows. |
| **P0** | Android v0.3.11 physical-device E2E | Signed APK ещё не собран и не установлен на телефон после этого patch. | Собрать signed APK, проверить подпись, Android VPN permission, native `VpnService`, profile/login, group connection, disconnect и logout на физическом устройстве. |
| **P1** | Native tray interaction | Реальный menu/window lifecycle не проверялся в GUI session. | На Windows и Linux проверить ПКМ menu, state-aware connect/disconnect, minimize-to-tray enabled/disabled и full quit. |
| **P1** | Полная локализация | Основные flows локализованы, но часть advanced labels всё ещё требует ручной языковой ревизии. | Пройти каждый экран в RU/EN на desktop и Android. |
| **P1** | Adaptive icon in dark theme | В assets/build paths есть иконки, но поведение launcher/taskbar в конкретных OS themes не верифицировано. | Проверить Windows taskbar/Explorer, Linux launcher и Android adaptive icon в light/dark mode. |

## 4. Публикационный статус

GitHub release `v0.3.10` уже публичен и содержит Windows/Linux artifacts; Android APK к нему не приложен. Сайт по-прежнему не должен переводиться на v0.3.10. Следующий релиз целесообразно создать как **v0.3.11**, только после закрытия обязательных проверок выше или при явном решении провести ограниченное техническое тестирование.

## 5. Изменения, которые должны войти в v0.3.11

1. DNS URL normalization, proxy listener preference mapping и соответствующие regression tests.
2. Изоляция сторонних subscription manifests от Mosaic smart-groups и защита `activeManifest`.
3. Version injection в Linux/Windows package scripts и GitHub CI.
4. Нейтральное финальное имя Android APK без «Technical Preview».
5. Flutter lint cleanup в unified account checkout panel.

## 6. Необходимые действия перед выпуском

Сначала требуется commit проверенных изменений и повторная сборка Linux package. Затем необходимы либо разрешённые production credentials/одноразовый testing flow, либо явное решение выпустить v0.3.11 только как технический релиз с сохранением предупреждения. Сайт не следует менять, пока не принято это решение.
