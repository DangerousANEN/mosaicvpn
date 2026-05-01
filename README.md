# Mosaic

A modular, gazetteer-styled VPN client for Windows.

Mosaic combines a Go daemon (`mosaicd`), a bundled
[sing-box](https://github.com/SagerNet/sing-box) engine, and a Tauri /
React GUI (`mosaic-ui`) into a single desktop installer. Subscriptions
are imported from any sing-box / Clash / v2ray / SIP008 source, every
station is GeoIP-resolved and pinned on a real world map, and Connect
opens a local SOCKS / HTTP proxy you can plug into your browser or
system settings.

> 🇷🇺 [Russian translation — README.ru.md](./README.ru.md)

---

## Highlights

- **Multi-protocol** — VLESS (+TLS / Reality, ws / grpc / xhttp), Hysteria2,
  Shadowsocks, Naive, AmneziaWG.
- **Real sing-box backend** — `Connect` actually opens a local proxy on
  `127.0.0.1:2080` (SOCKS) and `127.0.0.1:2081` (HTTP). No mock, no fake
  state.
- **Atlas-style UI** — cream paper, copper accents, Atlas Serif &
  JetBrains Mono. Built on a real equirectangular world map with
  per-station pins.
- **Automatic GeoIP** — every station is resolved through ip-api.com
  during *Test all* and cached in the local store, so the world map
  shows accurate locations even when subscriptions don't expose
  city / country metadata.
- **Subscription engine** — auto-detects sing-box JSON, Clash YAML, v2ray
  base64 (`vless://`, `vmess://`, `ss://`, `hysteria2://`, `naive+https://`),
  and SIP008.
- **Single-instance daemon** — global named mutex on Windows + lockfile
  carrying the loopback endpoint and bearer token. CLI, GUI and future
  MCP clients all attach to the same `mosaicd`.
- **Routing rule engine** — domain / IP-CIDR / GeoSite / GeoIP /
  process / port matching with AND/OR logic. (UI pass coming in a
  later RC.)
- **Local-only API** — `mosaicd` listens on `127.0.0.1:<random>` with a
  bearer token written into the lockfile. Nothing on the network can
  reach the daemon.

---

## Install

### Pre-built (Windows 10 / 11)

Grab the latest installer from the
[Releases](https://github.com/DangerousANEN/mosaicvpn/releases) page
(`Mosaic_<version>_x64-setup.exe`) and run it. The installer ships
`mosaic-ui.exe`, `mosaicd.exe`, and `sing-box.exe` under the install
directory you choose.

The installer is unsigned for now — Windows SmartScreen will warn the
first time you run it. *More info → Run anyway*. Code signing is
tracked on the roadmap.

### Quick start

1. Launch **Mosaic** from the Start menu.
2. Open **Pool**, paste a subscription URL, click **Add**.
3. Click **Test all** on the subscription card. Latency is probed via
   TCP and the daemon resolves each server's IP through ip-api.com so
   pins land in the right place on the map.
4. Click **Connect** on a station. The proxy listeners surface under the
   **Engage tunnel** button: `SOCKS · 127.0.0.1:2080  ·  HTTP · 127.0.0.1:2081`.
5. Point your browser, system proxy, or any tool that speaks SOCKS5 at
   that address. Verify with `curl --socks5 127.0.0.1:2080 https://ifconfig.me`.

### Uninstall

`Settings → Apps → Mosaic → Uninstall`. The user data dir at
`%APPDATA%\com.mosaicvpn.ui\daemon` survives uninstalls so you keep
your subscriptions and probes; delete it manually for a clean slate.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  mosaic-ui  (Tauri + React webview, system tray, splash)        │
│             ── HTTP + Bearer token over 127.0.0.1:<random> ──    │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  mosaicd  (Go daemon, single instance per host)            │ │
│  │   • api.Server     /v1/{status,connect,subs,servers,...}   │ │
│  │   • state.Manager  state machine + Backend interface       │ │
│  │   • subs.Parser    sing-box / Clash / v2ray-b64 / SIP008   │ │
│  │   • store.Store    atomic JSON state on disk               │ │
│  │   • single.Lock    named mutex + lockfile w/ token         │ │
│  │   • geoip          ip-api.com lookup, lat/lon cache        │ │
│  └────────────────────┬───────────────────────────────────────┘ │
│                       │ spawns + watches                          │
│  ┌────────────────────▼───────────────────────────────────────┐ │
│  │  sing-box.exe  (bundled v1.10.x, real proxy engine)        │ │
│  │   • generated config.json per Connect                       │ │
│  │   • SOCKS  127.0.0.1:2080                                   │ │
│  │   • HTTP   127.0.0.1:2081                                   │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Why three processes

- **`sing-box`** is the actual proxy engine. Mosaic does not reimplement
  VLESS or Hysteria2 — it generates a sing-box config and supervises
  the process. Crashes in sing-box do not bring down the daemon.
- **`mosaicd`** owns persistent state (subscriptions, servers, probe
  results, prefs, rules), a single source of truth via an HTTP API.
  Multiple clients (the GUI, the CLI, future MCP integrations) all
  drive it through the same API.
- **`mosaic-ui`** is the renderer. It does not write directly to disk
  and has no proxy code itself — it's strictly a view over the daemon.

### Data directory

`%APPDATA%\com.mosaicvpn.ui\daemon\` contains:

| File | Purpose |
|---|---|
| `daemon.lock` | JSON: host, port, bearer token, pid, version, started |
| `mosaicd.{out,err}.log` | structured logs from `mosaicd` |
| `singbox-current.json` | live sing-box config — useful for debugging |
| `singbox.{out,err}.log` | logs from the sing-box child process |
| `store.json` | subscriptions, servers, rules, prefs, last-server |

The lockfile is **not** exclusively locked on Windows since rc6 — any
client can read it.

---

## Building from source

### Prerequisites

- Go ≥ 1.23
- Node ≥ 20 + npm
- Rust ≥ 1.80 (for Tauri)
- A copy of `sing-box.exe` v1.10+ on PATH **or** placed next to
  `mosaicd` after `go build`. Without it, `Connect` falls back to a
  noisy mock backend.

### One-shot dev

```sh
# Linux / macOS
./scripts/dev.sh
```

```pwsh
# Windows
.\scripts\dev.ps1
```

These build `mosaicd`, build the renderer, place sing-box next to the
daemon, and launch the Tauri dev shell pointed at the local daemon.

### Manual

```sh
go test ./...
go build -o bin/mosaicd ./cmd/mosaicd
go build -o bin/mosaic ./cmd/mosaic

cd ui
npm ci
npm run build
npm run tauri dev      # for a dev window
npm run tauri build    # for a Windows installer
```

### Repository layout

```
cmd/
  mosaicd/         background daemon (HTTP API, state machine, store)
  mosaic/          CLI client; identical capabilities to the GUI
internal/
  api/             daemon HTTP API (bearer-token auth on loopback)
  apiclient/       Go client used by the CLI and (later) MCP
  geoip/           ip-api.com client
  logx/            structured slog wrapper
  paths/           cross-platform data-directory resolver
  proto/           API and storage types (single source of truth)
  rules/           routing rule engine
  single/          single-instance enforcement
  state/           connection state machine + Backend interface
                   (MockBackend, SingBoxBackend)
  store/           on-disk JSON store (atomic writes)
  subs/            subscription parsers (4 formats)
ui/
  src/             React renderer
  src-tauri/       Rust shell that spawns mosaicd + sing-box
docs/
  mockups/         original Atlas-aesthetic UI references
```

---

## Supported protocols

| Protocol | Status | Notes |
|---|---|---|
| VLESS | ✅ | TLS + Reality + ws / grpc / xhttp transports |
| Hysteria2 | ✅ | Optional `obfs=salamander` |
| Shadowsocks | ✅ | All AEAD ciphers sing-box ships |
| Trojan | partial | Parsed; not yet wired into sing-box config gen |
| VMess | partial | Parsed; not yet wired into sing-box config gen |
| Naive | ✅ | Native sing-box `naive` outbound (rc44); naive+https + naive+quic both supported |
| AmneziaWG | ✅ | Native sing-box `wireguard` + `amnezia_wg_settings` (rc44); accepts clash flat keys (jc, jmin, jmax, s1, s2, h1..h4) and nested sing-box JSON form |

---

## Agent integration (MCP)

Mosaic ships a Model Context Protocol server bound to loopback so AI
assistants (Claude Desktop, Cursor, Continue, …) can read its state and
optionally drive it: switch servers, refresh subscriptions, run latency
tests, manage auxiliary egresses.

Quick path:

1. Folio → Agent & MCP → toggle **MCP server** on, pick a permission
   level (default **connect**).
2. Open `%LOCALAPPDATA%\Mosaic\mcp.json` (Windows) — copy the `url` and
   `token`.
3. Drop them into your agent's MCP config; restart.

Full guide with copy-paste snippets for Claude Desktop / Cursor /
Continue, the per-tool permission table, and security notes lives at
[`docs/AGENTS-MCP.md`](docs/AGENTS-MCP.md).

---

## API surface

The daemon's HTTP API is documented inline in
[`internal/api/server.go`](internal/api/server.go). Highlights:

```
GET    /v1/status                  current connection + proxy listeners
POST   /v1/connect                 { server_id }
POST   /v1/disconnect

GET    /v1/subscriptions
POST   /v1/subscriptions           { url, name? }
POST   /v1/subscriptions/{id}/refresh
DELETE /v1/subscriptions/{id}

GET    /v1/servers
POST   /v1/servers/{id}/test       single TCP probe + GeoIP
POST   /v1/servers/test-all        parallel batch probe + GeoIP

GET    /v1/rules
POST   /v1/rules
DELETE /v1/rules/{id}
POST   /v1/rules:reorder

GET    /v1/prefs
PUT    /v1/prefs

GET    /v1/diag                    structured diagnostic dump
GET    /v1/events                  Server-Sent Events stream
```

Every request requires `Authorization: Bearer <token>` where `<token>`
is read from `daemon.lock`. The daemon refuses any non-loopback origin.

---

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Daemon + CLI + parsers + state machine | done (rc8) |
| 2a | Real sing-box backend, GeoIP, world map | done (rc9 / rc10) |
| 2b | UX polish: location-vs-name split, clickable pins | in progress |
| 3 | TUN backend (wintun) + kill-switch + DNS-leak prevention | planned |
| 4 | mosaicd as a Windows service (no UAC per Connect) | planned |
| 5 | MCP server + CLI feature parity | planned |
| 6 | Code signing + auto-update | planned |

---

## Credits

- [sing-box](https://github.com/SagerNet/sing-box) — proxy engine
- [simple-world-map](https://github.com/AndrewSouthpaw/simple-world-map)
  — equirectangular SVG, used as the map base
- [Tauri](https://tauri.app/) — desktop shell
- [ip-api.com](https://ip-api.com/) — free GeoIP service

---

## License

TBD. The project is currently in early development; no license has
been formally selected. Code in this repository is © its authors.
