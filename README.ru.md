# Mosaic

Модульный VPN-клиент для Windows в стиле старых атласов.

Mosaic собирает в один установщик Go-демон (`mosaicd`), вкомпилированный
[sing-box](https://github.com/SagerNet/sing-box) и Tauri / React-интерфейс
(`mosaic-ui`). Подписки импортируются из любого sing-box / Clash /
v2ray / SIP008 источника, каждая станция гео-резолвится по IP и
ставится на настоящую карту мира, а `Connect` поднимает локальный SOCKS /
HTTP прокси, который ты можешь воткнуть в браузер или в системные
настройки прокси.

> 🇬🇧 [English README](./README.md)

---

## Что внутри

- **Мульти-протокол** — VLESS (+TLS / Reality, ws / grpc / xhttp),
  Hysteria2, Shadowsocks, Naive, AmneziaWG.
- **Настоящий sing-box backend** — `Connect` реально открывает локальный
  прокси на `127.0.0.1:2080` (SOCKS) и `127.0.0.1:2081` (HTTP). Без
  мока и подделки состояния.
- **Atlas-стиль** — кремовая бумага, медные акценты, шрифт Atlas Serif +
  JetBrains Mono. Карта — настоящая equirectangular SVG со станциями-пинами.
- **Автоматический GeoIP** — на `Test all` каждая станция резолвится
  через `ip-api.com` и кешируется в локальном store, поэтому пины
  встают на правильные места даже если в подписке нет полей
  city / country.
- **Парсер подписок** — auto-detect: sing-box JSON, Clash YAML, v2ray
  base64 (`vless://`, `vmess://`, `ss://`, `hysteria2://`, `naive+https://`),
  SIP008, AmneziaWG / WireGuard `.conf` (`[Interface]` / `[Peer]`),
  AmneziaVPN `vpn://` экспорт. Можно подкинуть как URL подписки, так и
  локальный файл через **Import file…** в Pool.
- **Single-instance daemon** — global named mutex на Windows + lockfile
  с loopback-endpoint'ом и bearer-токеном. CLI, GUI и будущий MCP-клиент
  все цепляются к одному `mosaicd`.
- **Routing rule engine** — домены / IP-CIDR / GeoSite / GeoIP /
  процессы / порты с AND/OR-логикой. (UI к этому будет в одной из
  следующих RC.)
- **Только loopback API** — `mosaicd` слушает `127.0.0.1:<random>` с
  bearer-токеном из lockfile. Из сети до демона добраться нельзя.

---

## Установка

### Готовый билд (Windows 10 / 11)

Скачай свежий установщик со страницы
[Releases](https://github.com/DangerousANEN/mosaicvpn/releases)
(`Mosaic_<version>_x64-setup.exe`) и запусти. В установщике лежат
`mosaic-ui.exe`, `mosaicd.exe` и `sing-box.exe` — все три попадают в
выбранную тобой папку установки.

Установщик пока не подписан — Windows SmartScreen ругнётся при первом
запуске. *Подробнее → Выполнить в любом случае*. Code signing — в
roadmap.

### Быстрый старт

1. Запусти **Mosaic** через меню Пуск.
2. Открой **Pool**, вставь URL подписки и жми **Add** — или
   **Import file…**, чтобы подгрузить локальный файл `.conf`
   (WireGuard / AmneziaWG), `vpn://` (экспорт AmneziaVPN), `.yaml`
   (Clash) или `.json` (sing-box).
3. На карточке подписки жми **Test all**. Daemon TCP-пробит каждую
   станцию и резолвит её IP через `ip-api.com`, после чего пины на
   карте встают по настоящим координатам.
4. Жми **Connect** на нужной станции. Под кнопкой **Engage tunnel**
   появится строчка с адресами прокси:
   `SOCKS · 127.0.0.1:2080  ·  HTTP · 127.0.0.1:2081`.
5. Воткни этот адрес в браузер, системный прокси или в любой инструмент,
   умеющий SOCKS5. Проверка:
   `curl --socks5 127.0.0.1:2080 https://ifconfig.me` — должен вернуть
   IP сервера, а не твой.

### Удаление

`Параметры → Приложения → Mosaic → Удалить`. Папка с пользовательскими
данными `%APPDATA%\com.mosaicvpn.ui\daemon` остаётся, чтобы подписки и
история тестов не пропадали; удали её руками если нужен чистый старт.

---

## Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│  mosaic-ui  (Tauri + React webview, tray, splash)               │
│             ── HTTP + Bearer token over 127.0.0.1:<random> ──    │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  mosaicd  (Go-демон, single-instance per host)             │ │
│  │   • api.Server     /v1/{status,connect,subs,servers,...}   │ │
│  │   • state.Manager  state machine + Backend interface       │ │
│  │   • subs.Parser    sing-box / Clash / v2ray-b64 / SIP008   │ │
│  │   • store.Store    атомарный JSON-store на диске           │ │
│  │   • single.Lock    named mutex + lockfile с токеном        │ │
│  │   • geoip          ip-api.com lookup, кеш lat/lon          │ │
│  └────────────────────┬───────────────────────────────────────┘ │
│                       │ spawn + watch                            │
│  ┌────────────────────▼───────────────────────────────────────┐ │
│  │  sing-box.exe  (bundled v1.10.x, реальный proxy engine)    │ │
│  │   • config.json генерится на каждый Connect                 │ │
│  │   • SOCKS  127.0.0.1:2080                                   │ │
│  │   • HTTP   127.0.0.1:2081                                   │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Зачем три процесса

- **`sing-box`** — это сам proxy engine. Mosaic не переписывает VLESS
  или Hysteria2, а генерит для sing-box конфиг и присматривает за
  процессом. Падение sing-box не валит демон.
- **`mosaicd`** держит всё persistent state (подписки, серверы, пинги,
  prefs, rules) и отдаёт его через HTTP API. К одному `mosaicd`
  одновременно цепляются GUI, CLI и (в будущем) MCP-клиенты.
- **`mosaic-ui`** — только рендерер. Он не пишет ничего на диск и не
  содержит proxy-кода: чисто view над демоном.

### Папка с данными

`%APPDATA%\com.mosaicvpn.ui\daemon\`:

| Файл | Что внутри |
|---|---|
| `daemon.lock` | JSON: host, port, bearer token, pid, version, started |
| `mosaicd.{out,err}.log` | структурированные логи демона |
| `singbox-current.json` | текущий конфиг sing-box — полезно для отладки |
| `singbox.{out,err}.log` | логи sing-box |
| `store.json` | подписки, серверы, правила, prefs, last-server |

С rc6 lockfile **не** держится в эксклюзивном lock'е на Windows — любой
клиент может его читать.

---

## Сборка из исходников

### Что нужно

- Go ≥ 1.23
- Node ≥ 20 + npm
- Rust ≥ 1.80 (для Tauri)
- `sing-box.exe` v1.10+ либо в PATH, либо рядом с `mosaicd` после
  `go build`. Без него `Connect` падает в шумный mock backend.

### В одну команду

```sh
# Linux / macOS
./scripts/dev.sh
```

```pwsh
# Windows
.\scripts\dev.ps1
```

Они собирают `mosaicd`, рендерер, кладут sing-box рядом с демоном и
запускают Tauri dev-окно, нацеленное на локальный демон.

### Руками

```sh
go test ./...
go build -o bin/mosaicd ./cmd/mosaicd
go build -o bin/mosaic ./cmd/mosaic

cd ui
npm ci
npm run build
npm run tauri dev      # окно для разработки
npm run tauri build    # установщик под Windows
```

### Структура репозитория

```
cmd/
  mosaicd/         фоновый демон (HTTP API, state machine, store)
  mosaic/          CLI; те же возможности что у GUI
internal/
  api/             HTTP API (bearer-token auth, только loopback)
  apiclient/       Go-клиент для CLI и (позже) MCP
  geoip/           клиент ip-api.com
  logx/            обёртка над slog
  paths/           кросс-платформенный резолв data-dir
  proto/           типы API и хранилища (single source of truth)
  rules/           routing rule engine
  single/          single-instance enforcement
  state/           state machine + Backend interface
                   (MockBackend, SingBoxBackend)
  store/           JSON-store на диске (atomic writes)
  subs/            парсеры подписок (4 формата)
ui/
  src/             React-рендерер
  src-tauri/       Rust-shell, спавнящий mosaicd + sing-box
docs/
  mockups/         оригинальные Atlas-мокапы
```

---

## Поддержка протоколов

| Протокол | Статус | Заметки |
|---|---|---|
| VLESS | ✅ | TLS + Reality + ws / grpc / xhttp transports |
| Hysteria2 | ✅ | Опционально `obfs=salamander` |
| Shadowsocks | ✅ | Все AEAD-шифры из sing-box |
| Trojan | partial | Парсится; ещё не разводится в sing-box config |
| VMess | partial | Парсится; ещё не разводится в sing-box config |
| Naive | ✅ | Нативный outbound sing-box `naive` (rc44); поддерживаются и naive+https, и naive+quic |
| AmneziaWG | ✅ | Нативный sing-box `wireguard` + `amnezia_wg_settings` (rc44); понимает плоские ключи clash (jc, jmin, jmax, s1, s2, h1..h4) и вложенный sing-box JSON |

---

## Подключение AI-агента (MCP)

Mosaic поднимает MCP-сервер на loopback, через который сторонние
ассистенты (Claude Desktop, Cursor, Continue, …) читают состояние и при
необходимости рулят клиентом: переключают серверы, обновляют подписки,
гоняют латенси-тесты, заводят вспомогательные egress'ы.

Краткий путь:

1. Folio → Agent & MCP → включить **MCP server**, выбрать уровень
   разрешений (по умолчанию **connect**).
2. Открыть `%LOCALAPPDATA%\Mosaic\mcp.json` и скопировать `url` + `token`.
3. Вставить в конфиг MCP-клиента, перезапустить.

Полный гайд со сниппетами для Claude Desktop / Cursor / Continue,
матрицей разрешений по tool'ам и заметками о безопасности:
[`docs/AGENTS-MCP.md`](docs/AGENTS-MCP.md).

---

## API

HTTP API демона задокументирован прямо в коде — см.
[`internal/api/server.go`](internal/api/server.go). Основное:

```
GET    /v1/status                  текущее состояние + proxy-listener'ы
POST   /v1/connect                 { server_id }
POST   /v1/disconnect

GET    /v1/subscriptions
POST   /v1/subscriptions           { url, name? }
POST   /v1/subscriptions/{id}/refresh
DELETE /v1/subscriptions/{id}

GET    /v1/servers
POST   /v1/servers/{id}/test       одиночный TCP-probe + GeoIP
POST   /v1/servers/test-all        батч-probe всех + GeoIP

GET    /v1/rules
POST   /v1/rules
DELETE /v1/rules/{id}
POST   /v1/rules:reorder

GET    /v1/prefs
PUT    /v1/prefs

GET    /v1/diag                    диагностика
GET    /v1/events                  Server-Sent Events
```

Каждому запросу нужен `Authorization: Bearer <token>`, где `<token>` —
из `daemon.lock`. На любой не-loopback origin демон возвращает отказ.

---

## Roadmap

| Фаза | Что | Статус |
|---|---|---|
| 1 | Демон + CLI + парсеры + state machine | done (rc8) |
| 2a | Реальный sing-box backend, GeoIP, карта мира | done (rc9 / rc10) |
| 2b | UX-полировка: разнос локации и имени, кликабельные пины | в работе |
| 3 | TUN backend (wintun) + kill-switch + DNS-leak prevention | в плане |
| 4 | mosaicd как Windows-сервис (без UAC на каждый Connect) | в плане |
| 5 | MCP-сервер + полная feature-parity с CLI | в плане |
| 6 | Code signing + автообновление | в плане |

---

## Благодарности

- [sing-box](https://github.com/SagerNet/sing-box) — proxy engine
- [simple-world-map](https://github.com/AndrewSouthpaw/simple-world-map)
  — equirectangular SVG в качестве базы карты
- [Tauri](https://tauri.app/) — desktop shell
- [ip-api.com](https://ip-api.com/) — бесплатный GeoIP

---

## Лицензия

Пока не выбрана. Проект на ранней стадии. Код в этом репозитории —
© его авторов.
