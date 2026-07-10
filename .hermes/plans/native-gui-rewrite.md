# MosaicVPN Native GUI — Rust + Slint Rewrite Plan

## Architecture (Throne-style, Rust instead of C++/Qt)

```
┌──────────────────────────┐         ┌─────────────────────────────┐
│   Slint GUI (Rust)       │         │   Go Core (unchanged)       │
│   — native window        │         │   — sing-box + xray-core    │
│   — atlas visual style   │  Named  │   — HTTP API (existing)     │
│   — 15MB target          │  Pipe   │   — MCP server              │
│                          │◄──────►│   — egress routing           │
│   HTTP localhost → Go    │         │   — geoip, rules, store     │
└──────────────────────────┘         └─────────────────────────────┘
```

**Key decision**: The Go backend stays as-is. The GUI is rewritten from React/Tauri to
Rust + Slint. Communication is via the existing HTTP API (localhost), not protobuf/IPC —
this eliminates the need for a custom RPC layer and keeps the Go backend untouched.

**Why HTTP not protobuf-over-named-pipe (like Throne)?**
- Go backend already exposes a full HTTP API with auth (`internal/api/server.go`)
- Tauri frontend already uses this API (`ui/src/api/client.ts`)
- Less plumbing — reuse what works. HTTP on loopback is fast enough for a VPN client
- If we later want to embed sing-box directly (no Go process), we switch to gRPC then

## Phase 1: Scaffold the Rust project

### 1.1 — Cargo workspace structure

```
mosaicvpn/
├── go.mod                          (existing Go backend)
├── internal/                       (existing Go backend)
├── native/                         (NEW — Rust GUI)
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs                 (Slint app entry)
│   │   ├── api.rs                  (HTTP client → Go backend)
│   │   ├── models.rs               (Rust structs matching Go proto types)
│   │   ├── app.rs                  (Slint component, state, timer)
│   │   ├── components/             (Slint UI .slint files)
│   │   │   ├── app.slint
│   │   │   ├── main.slint          (Main screen — world map + connect)
│   │   │   ├── pool.slint          (Pool — subscription gazetteer)
│   │   │   ├── folio.slint         (Folio — settings)
│   │   │   └── shared.slint        (shared themes, fonts)
│   │   └─ themes/
│   │       └── atlas.rs            (Mosaic Atlas colour palette)
│   └── assets/
│       ├── world.svg               (atlas world map)
│       └── fonts/                   (Atlas Serif, JetBrains Mono)
└── ui/                             (existing Tauri — kept for reference)
```

### 1.2 — Cargo.toml dependencies

```toml
[package]
name = "mosaicvpn-native"
version = "0.1.0"
edition = "2024"

[dependencies]
slint = "1.8"
reqwest = { version = "0.12", features = ["blocking", "json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["rt", "macros", "time"] }
dirs = "5"
```

**Build target**: `-C opt-level=3` for release. Strip symbols.
**Target RAM**: ~15MB with Slint's software renderer (no GPU process).

### 1.3 — Verify Slint builds on Windows

- `cargo add slint`
- Build a hello-world Slint window
- Verify RAM usage with Task Manager (should be <30MB even with debug build)
- This is the go/no-go checkpoint

## Phase 2: API client (Rust → Go HTTP)

### 2.1 — Port `ui/src/api/types.ts` to Rust `models.rs`

All types from `internal/proto/types.go`:
- `Server`, `Subscription`, `Rule`, `Prefs`, `Status`
- `State` enum (disconnected, connecting, connected, error)

### 2.2 — Port `ui/src/api/client.ts` to Rust `api.rs`

- `ApiClient { base_url, token }`
- Read token from lockfile (same as Tauri does via `/v1/ping`)
- All endpoints:
  - `list_subscriptions()`, `add_subscription()`, `rename_subscription()`, `delete_subscription()`, `refresh_subscription()`
  - `list_servers()`, `test_server()`, `test_all_servers()`
  - `connect()`, `disconnect()`, `status()`
  - `get_prefs()`, `set_prefs()`
  - `list_rules()`, `add_rule()`, `delete_rule()`, `reorder_rules()`
- SSE stream for status events (use `reqwest` streaming)

## Phase 3: Slint UI — Main screen (world map + connect)

### 3.1 — Atlas theme

Mosaic Atlas visual style (from memory):
- Light: bg #F4EFE3, ink #2B2A27, copper #C85A32
- Dark: bg #13110F, ink #C5A880, copper #B87333
- Serif + mono type pair
- ◆ icons, no emoji in UI
- Terms: Station=server, Plate=section, Folio=settings, "Engage tunnel »"=connect

### 3.2 — Main.slint

- World map (SVG loaded via Slint Image)
- Connect/disconnect button with ◆ status indicator
- Current station info (name, latency, protocol)
- Tabs: Main · Pool · Folio
- Status bar at bottom

## Phase 4: Slint UI — Pool screen (subscriptions)

- Numbered subscription cards
- Stats per sub (stations, live, median, best)
- Add subscription input at bottom
- Inline rename (double-click name)
- Expand to show station list
- Refresh / Test all / Delete actions per card

## Phase 5: Slint UI — Folio screen (settings)

- Network: tunnel mode (TUN/proxy), TUN stack (system/gvisor/mixed)
- Privacy: kill switch, DNS
- Auto-start: launch on boot
- Agent & MCP: toggle, port
- Save/discard with auto-reconnect (backend already handles this)

## Phase 6: Process lifecycle

### 6.1 — Daemon management

- On app launch: check if Go daemon is running (GET `/v1/ping`)
- If not: spawn `mosaicvpn-daemon` as child process
- On app quit: optionally keep daemon running (systemd-style background service)
- Lockfile: read port + auth token from `~/.mosaicvpn/lock.json` (or wherever Go writes it)

### 6.2 — System tray

- Slint supports tray on Windows via `tray-icon` crate
- "Connect", "Disconnect", "Settings", "Quit" menu
- Minimize to tray on close

## Phase 7: Build & distribution

### 7.1 — Windows

- Static link Slint (no runtime DLLs needed)
- `cargo build --release` → strip → ~8-12MB binary
- WiX or NSIS installer
- Windows auto-start via Registry entry

### 7.2 — Cross-platform

- Linux: Wayland/X11 via Slint
- macOS: Metal renderer via Slint (later)

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| GUI framework | Slint | Native GPU rendering, 15MB RAM, no Chromium |
| Core | Go (existing) | sing-box + xray already integrated, don't rewrite |
| IPC | HTTP (existing) | Reuse working API, no new protocol layer |
| Renderer | Slint software | Minimal RAM, no GPU process needed |
| Build | Cargo workspace | Separate `native/` from Go backend |

## What stays from the Tauri version

- **Go backend**: 100% reuse — `internal/store`, `internal/api`, `internal/state`, `internal/subs`
- **Visual identity**: Mosaic Atlas aesthetic, same color palette, typography
- **MCP + egresses**: untouched (Go-side)
- **Subscription parser**: untouched (Go-side)

## What changes

| Component | Tauri (current) | Native (target) |
|---|---|---|
| GUI | React + Tauri (Chromium) | Rust + Slint (GPU/software) |
| RAM | ~150-200MB (Chromium) | ~15MB target |
| Binary size | ~50MB+ (Tauri) | ~8-12MB |
| Startup | ~2-5s (Chromium init) | <0.5s (native) |
| Renderer | Chromium Skia | Slint (software or GPU) |

## Verification checkpoints

1. **Slint compiles on Windows** — hello world window, verify in Task Manager
2. **API client loads data** — `list_subscriptions()` returns JSON from Go daemon
3. **Main screen renders** — world map + connect button
4. **Connect/disconnect works** — calls `api.connect()`, status updates via SSE
5. **Pool screen works** — add/rename/delete subscriptions, expand stations
6. **RAM < 30MB** — measure with Windows Task Manager
7. **Binary < 15MB** — `ls -lh` on release binary

## Files to reference

- `ui/src/api/client.ts` — all API endpoints (port to Rust)
- `ui/src/api/types.ts` — all types (port to Rust)
- `internal/proto/types.go` — source of truth for types
- `internal/api/server.go` — all routes
- `ui/src/screens/Main.tsx` — Main screen layout reference
- `ui/src/screens/Pool.tsx` — Pool screen layout reference
- `ui/src/screens/Folio.tsx` — Folio screen layout reference
- `ui/src/styles/pool.css` — Atlas visual style reference
