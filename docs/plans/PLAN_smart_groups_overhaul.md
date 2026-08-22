# План: Smart Groups Overhaul + Клиентские фиксы + Админка

> **Дата:** 18 августа 2026
> **Приоритет:** по порядку выполнения
> **Основа:** данные трёх полных аудитов (Go-демон, Flutter клиент, VPS инфра)

---

## Фаза 1: Go-демон — критические фиксы (10 задач)

### 1.1 Watchdog: детект падения sing-box → StateError
**Файл:** `internal/state/singbox_backend.go:200–212`
**Проблема:** Горутина `cmd.Wait()` после завершения sing-box только логирует `"sing-box exited"` и закрывает `doneCh`, но НЕ уведомляет `state.Manager` → UI навечно висит в `StateConnected`.
**Решение:** Добавить callback `onUnexpectedExit func(error)` в `SingBoxBackend`, вызывать из горутины `cmd.Wait()`. В `state.Manager` — подписаться: `transitionLocked(StateError, err)` + триггерить авто-реконнект.

### 1.2 Авто-реконнект при потере соединения (seamless failover)
**Файл:** `internal/state/state.go`
**Проблема:** Нет авто-реконнекта после неожиданного disconnect.
**Решение:** После watchdog-срабатывания:
1. `transitionLocked(StateReconnecting)` → новое состояние
2. Вызвать `Resolve()` (приоритетная цепочка) для выбора следующей ноды
3. Попытка `Connect()` с экспоненциальным backoff (1s, 2s, 4s, 8s, max 30s)
4. Не более 10 попыток → потом `StateError` с сообщением "все ноды недоступны"
5. Отправлять SSE-событие `reconnecting` клиенту

### 1.3 Kill Switch — реально подключить к connect/disconnect
**Файл:** `internal/state/state.go`, `internal/killswitch/`
**Проблема:** `ks.Enable()` / `ks.Disable()` нигде не вызывается в connect/disconnect.
**Решение:** В `Manager.Connect()` → после `backend.Start()` success → `ks.Enable(tunnelIface, serverIP, dns)`. В `Manager.Disconnect()` → `ks.Disable()`. В watchdog → при crash: НЕ отключать killswitch (защита от утечки).

### 1.4 Pool engine: перезапуск после добавления подписки
**Файл:** `internal/api/server.go:1091–1127` (refresh), `server.go:1470–1479` (StartPool)
**Проблема:** `StartPool` — no-op если manifest ещё не загружен при старте демона. После `refresh()` pool не перезапускается.
**Решение:** В конце `refresh()` → вызвать `s.restartPool()` который cancels старый контекст и стартует заново.

### 1.5 Лёгкие серверные health checks (не TCP)
**Файл:** `internal/subs/pool.go`
**Проблема:** TCP dial каждые 30 секунд для 100+ нод — тяжело. Но TCP — единственное что есть.
**Решение:** Заменить на:
- ICMP ping (3 пакета, средняя + джиттер) через go-ping — дешевле TCP
- Интервал: 120 секунд (вместо 30)
- Concurrency limit: 10 одновременных проверок (semaphore)
- Сохранять `{alive, latencyAvg, latencyP95, jitter, packetLoss, lastCheck}`
- Мёртвые ноды (3 промаха подряд) → интервал 600 секунд (reduced polling)

### 1.6 Клиентские расширенные health checks
**Файл:** `internal/subs/pool.go` — новая функция `DeepProbe()`
**Проблема:** Нужны достоверные проверки: handshake latency, jitter, packet loss, реальная скорость.
**Решение:** Новый эндпоинт `POST /v1/groups/{id}/deep-probe`:
1. TLS Handshake latency (connect + handshake timer)
2. HTTP GET `generate_204` → real latency
3. 3 последовательных probe → jitter = max-min
4. Packet loss: 5 ICMP → процент потерь
5. Optional mini speed test: 10KB download за N ms
6. Результат: `{probeType:"deep", handshakeMs, httpMs, jitter, packetLoss%, downloadKbps}`

### 1.7 Whitelist bypass смарт-группа — улучшение
**Файл:** `internal/subs/manifest.go:131–313` (SynthesizeManifest), `internal/state/singbox_backend.go:374–464`
**Текущее:** `auto-whitelist` уже существует, но:
- type=`fallback` (не `urltest`) — плохой выбор ноды
- Нет рулсета для доменов белого списка (госсайты, банки)
- Фильтрация: name/tag contains "whitelist"/"4g"/"tspu" — грубая эвристика
**Решение:**
1. Добавить в sing-box конфиг `rule_set` с доменами `.gosuslugi.ru`, `.nalog.ru`, `.sberbank.ru`, `.vtb.ru`, `.tinkoff.ru` и т.д. → route через `auto-whitelist` outbound
2. Сменить тип на `urltest` с target `https://yandex.ru/generate_204`
3. Добавить эндпоинт `GET /v1/whitelist-domains` для получения списка
4. Хранить список доменов в отдельном файле `whitelist_domains.json` рядом с manifest

### 1.8 Seed default groups при первом запуске
**Файл:** `internal/store/store.go`, `cmd/mosaicd/main.go`
**Проблема:** `pool-auto` и `emergency` группы нигде не создаются → шаги 3–4 resolve chain всегда fail.
**Решение:** В `main.go` после `store.Open()` → `store.SeedDefaultGroups()`.

### 1.9 VMess / TUIC — не терять протокол
**Файл:** `internal/subs/v2ray.go:157, 304`
**Проблема:** VMess → VLess, TUIC → VLess (lossy coercion).
**Решение:** Хранить как `ProtoVMess` и `ProtoTUIC`, добавить соответствующие outbound-генераторы в `singbox_backend.go`.

### 1.10 Deep-link import endpoint
**Файл:** `internal/api/server.go`
**Проблема:** `POST /v1/import/link` не парсит ссылку в полноценный Server, только определяет протокол.
**Решение:** Добавить `POST /v1/import/subscription-link` который принимает `{url}`, создаёт одноразовую подписку и вызывает `refresh()`.

---

## Фаза 2: Flutter клиент — фиксы и фичи (9 задач)

### 2.1 Фикс ошибки "Не удалось подключиться" в Groups экране
**Файл:** `flutter/lib/features/manifest_groups/groups_screen.dart:213–228`
**Проблема:** `_connectGroup()` делает 2 последовательных HTTP вызова (selectNode + connect), оба могут упасть, но ошибка одна.
**Решение:**
1. Разделить try/catch: отдельное сообщение для "не найдена нода в группе" и "не удалось подключиться к ноде"
2. При `DioException.connectionTimeout` → "Демон не запущен или не отвечает"
3. При 404 от selectNode → "В группе нет живых серверов"

### 2.2 Фикс ошибки в Routing screen (silent failures)
**Файл:** `flutter/lib/features/routing/routing_screen.dart:63,88`
**Проблема:** Все ошибки уходят в `debugPrint` — юзер не видит.
**Решение:** Заменить `debugPrint` → `ScaffoldMessenger.showSnackBar` с красной плашкой.

### 2.3 Deep-link handler (mosaic:// / mosaicvpn://)
**Файлы:** `pubspec.yaml`, `AndroidManifest.xml`, `flutter/lib/main.dart`, `flutter/lib/app/app.dart`
**Проблема:** Полностью отсутствует. Кнопка "Добавить в MosaicVPN" на сайте мертва.
**Решение:**
1. Добавить `app_links: ^6.3.0` в pubspec.yaml
2. В `AndroidManifest.xml`: `<intent-filter autoVerify="true">` + `<data android:scheme="mosaic" />` + `<data android:scheme="mosaicvpn" />`
3. Windows: NSIS регистрация протокола `mosaic://` в реестре
4. Linux: `.desktop` файл с `MimeType=x-scheme-handler/mosaic`
5. В `main.dart`: слушать `appLinks.uriLinkStream` → парсить URL → если `mosaic://add?url=<sub_url>` → вызвать `api.addSubscription()`
6. Показать диалог "Подписка добавлена!" или ошибку

### 2.4 Provider redesign — daemonApiProvider
**Файл:** `flutter/lib/core/providers/vpn_providers.dart:131–178`
**Проблема:** Создаёт новый `_ResolvedDaemonApi` на каждый `ref.read`. Не ребилдится при рестарте демона.
**Решение:** Заменить на `AsyncNotifierProvider` с `keepAlive`, lazy init, и file watcher на daemon.lock.

### 2.5 Platform guards
**Файлы:**
- `daemon_launcher.dart:68` — `Process.start` без проверки `Platform.isAndroid`
- `dashboard_screen.dart:1950` — `powershell` без проверки `Platform.isWindows`
- autostart service — `Process.runSync('reg', ...)` без проверки
**Решение:** Обернуть каждый вызов в `if (Platform.isWindows)` / `if (!Platform.isAndroid)`.

### 2.6 Android: заглушка / proxy mode
**Файлы:** `daemon_launcher.dart`, `vpn_providers.dart`
**Проблема:** Android не может запустить Go-демон через Process.start.
**Решение:** (Минимальная):
1. На Android — пропускать `DaemonLauncher`, сразу переходить к API (если демон запущен внешне)
2. Добавить настройку "Адрес демона" для ручного ввода (`host:port`)
3. Для TUN режима — TODO: gomobile AAR (отдельный спринт, не в этом плане)

### 2.7 `_isGroupActive` — фикс race condition
**Файл:** `flutter/lib/features/manifest_groups/groups_screen.dart:196–203`
**Проблема:** `ref.read(serversProvider).valueOrNull` может вернуть `[]` до загрузки.
**Решение:** Передавать уже загруженный список серверов через параметр виджета.

### 2.8 Убрать hardcoded путь
**Файл:** `flutter/lib/core/services/daemon_launcher.dart:28`
**Проблема:** `C:\\Users\\ANEN\\mosaicvpn\\bin\\mosaicd.exe` в продакшн коде.
**Решение:** Использовать `Platform.resolvedExecutable` parent directory + `mosaicd.exe`.

### 2.9 Status polling — показывать reconnecting
**Файл:** `flutter/lib/core/providers/vpn_providers.dart:396–421`
**Решение:** Добавить обработку нового состояния `StateReconnecting` → UI показывает "Переподключение..." с анимацией спиннера.

---

## Фаза 3: Сайт — админка (4 задачи)

### 3.1 Broadcast через admin.html
**Файл:** `site/admin.html` → deploy на VPS `/etc/letsencrypt/landing/admin.html`
**Проблема:** Broadcast только через Telegram бот `/broadcast`.
**Решение:** Добавить форму: textarea + "Отправить всем" кнопка → `POST /api/admin/broadcast` → бот рассылает.

### 3.2 Управление ценой VPN (руб/день)
**Решение:** Добавить в admin.html секцию "Тарифы":
- Текущая цена за день (читается из `GET /api/admin/config`)
- Инпут для новой цены + кнопка "Сохранить" → `PUT /api/admin/config/price`
- Бот и кабинет читают цену из БД/конфига, а не захардкоженного `PACKAGES`

### 3.3 Управление промокодами
**Решение:** Добавить в admin.html секцию "Промокоды":
- Таблица: код, скидка%, дней бонуса, макс. использований, использовано, статус
- Форма создания: код + дней + скидка% + лимит
- Кнопка деактивации
- Всё через API бота

### 3.4 Выдача баланса всем с сообщением
**Решение:** Расширить текущую форму balance-credit:
- Вместо "одному юзеру" → чек "Всем пользователям"
- Поле "Сообщение" (например "Извините за недоступность сервиса")
- `POST /api/admin/balance-credit-all` → бот кредитит всех + отправляет сообщение

---

## Фаза 4: VPS инфра — оптимизация (3 задачи)

### 4.1 Лёгкие серверные health checks вместо тяжёлого sing-box пула
**Проблема:** `selector_v2.py` каждые 6 часов скачивает 100+ нод, строит sing-box конфиг, sing-box гоняет urltest каждые 15с для 120 нод.
**Решение:**
1. Заменить `selector_v2.py` на лёгкий `health_monitor.py`:
   - ICMP ping (не TCP) каждые 120с
   - Concurrency limit: 10
   - Результат: JSON с alive/latency/jitter для каждой ноды
   - Доступен клиентам через `GET /api/pool-health.json`
2. Клиент подтягивает этот JSON + проводит свои deep probes
3. `sing-box-pool.service` → постепенное отключение (disable, но не удалять пока)

### 4.2 Почистить мусор
- `rm /etc/sing-box-pool/config.json.bak.*` (13 файлов)
- Обновить manifest: `payment_methods` → Lava, CryptoPay (убрать YooMoney)

### 4.3 API endpoint для клиентских health reports
**Решение:** `POST /api/client-health-report` — клиент отправляет результаты своих deep probe → сервер агрегирует → лучшая картина реального QoS.

---

## Порядок выполнения

1. **Go-демон Фаза 1:** 1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.8 → 1.10
2. **Flutter Фаза 2:** 2.1 → 2.2 → 2.5 → 2.8 → 2.7 → 2.3 → 2.4 → 2.9 → 2.6
3. **Сайт Фаза 3:** 3.1 → 3.4 → 3.2 → 3.3
4. **VPS Фаза 4:** 4.2 → 4.1 → 4.3
5. **Позже:** 1.6, 1.7, 1.9 (усовершенствования)
