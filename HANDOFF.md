# Handoff — MosaicVPN

> This document is written FOR the next coding agent picking up the
> project. It is not user-facing documentation — see `README.md` /
> `README.ru.md` for that. Read this top-to-bottom before touching any
> code; it captures everything the previous agent learned so you don't
> have to re-discover it.

Last updated: rc23 shipped. Original rc16 docket of 12 bugs is fully
addressed across rc17–rc23; the user has since opened a second batch
of feedback (rc21–rc23 cycle) — see §11 for the live status of each.

**Stack of unmerged rc PRs (none merged by user):**
PR #11 (HANDOFF rc20) ← #12 (rc21 TUN backend) ← #13 (rc22 country
clustering / LAN share / live polling) ← #14 (rc23 map v2 / proxy
default migration / reconnect-to-last / Pool URL overflow). User
intends to merge in numeric order.

**Active branch for next session:**
`devin/1777403083-rc23-feedback`. Branch off this for rc24.

---

## 1. Repo & owner facts

- GitHub: <https://github.com/DangerousANEN/mosaicvpn>
- Default branch: `main`
- Live tags: `v0.1.0-rc2` … `v0.1.0-rc20` (each tag triggers a
  Windows build via `.github/workflows/release.yml` and uploads
  `Mosaic_0.1.0_x64-setup.exe` as an artifact).
- **None of the rc PRs have been merged by the user yet.** Every rc
  release was tagged from a feature branch directly. Open PRs at the
  time of writing: #1 (rc12 grouping), #2 (HANDOFF), #3 (rc13),
  #4 (rc14), #5 (rc15), #6 (rc16), #7 (rc17), #8 (rc18), #9 (rc19),
  #10 (rc20). They are stacked: each branched off the previous one,
  so the user must merge in numeric order or accept GitHub's
  rebase-on-merge conflicts.
- Branch naming has been `devin/<timestamp>-<topic>` since rc13. The
  rc20 branch is `devin/1777383000-rc20-shutdown-fix`.
- Module path: `github.com/DangerousANEN/mosaicvpn`. As of rc20 the
  Go module path matches the GitHub org; previous tags (rc≤19) used a
  legacy `pupspochta-cpu/mosaicvpn` path inherited from the initial
  scaffold. The rename is a no-op for builds (Go resolves internal/*
  through go.mod) but cleans up stack traces and lets `go install` from
  the GitHub URL work.

## 2. User context

- Single primary user: `johndoedal2` (reachable through Devin chat).
- Native Russian speaker — replies in Russian. Translate in your
  responses; technical terms can stay English.
- User runs Windows; install dir is `F:\aProgramms\Mosaic\` containing
  three exes: `mosaic-ui.exe`, `mosaicd.exe`, `sing-box.exe`.
- Daemon data dir: `%APPDATA%\com.mosaicvpn.ui\daemon\`.
- User prefers terse, direct, technical messages. Don't over-explain
  obvious things. They will tell you to "не правь, обсудим" when they
  want planning before coding.
- The user gave us a real subscription URL for testing:
  `http://206.251.50.217:8888/sub.txt`. Do NOT actually `Connect` to
  these servers from your VM, only `Test`. Some are flaky and you'll
  break their connectivity.

## 3. Architecture in one diagram

```
┌─ mosaic-ui ─ Tauri React webview, system tray ──────────────────┐
│           HTTP + Bearer token over 127.0.0.1:<random>           │
│  ┌─ mosaicd (Go) ─ single-instance daemon ───────────────────┐  │
│  │  api.Server  /v1/{status,connect,subs,servers,rules,…}    │  │
│  │  state.Manager  state machine + Backend interface         │  │
│  │  subs.Parser    sing-box / Clash / v2ray-b64 / SIP008     │  │
│  │  store.Store    atomic JSON state on disk (store.json)    │  │
│  │  single.Lock    named mutex + lockfile w/ token           │  │
│  │  geoip          ip-api.com lookup, lat/lon cache          │  │
│  └──────────┬────────────────────────────────────────────────┘  │
│             │ spawns + supervises                                │
│  ┌──────────▼──── sing-box.exe ── bundled v1.10.x ──────────┐   │
│  │  config.json regenerated per Connect                      │   │
│  │  SOCKS  127.0.0.1:2080                                    │   │
│  │  HTTP   127.0.0.1:2081                                    │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### Three processes — why

- `sing-box` is the proxy engine. Mosaic does NOT reimplement VLESS /
  Hysteria2; we generate a sing-box config and supervise the process.
- `mosaicd` owns persistent state and exposes everything via HTTP.
  Multiple clients (GUI, CLI, future MCP) all talk to it.
- `mosaic-ui` is strictly a view — no disk writes, no proxy code.

## 4. Repo layout (the parts that matter)

```
cmd/
  mosaicd/         daemon entry (cmd/mosaicd/main.go)
  mosaic/          CLI client (mostly unused; kept in sync)
internal/
  api/             HTTP API + handlers
                   server.go is THE place for routing, probes, geoip
  apiclient/       Go HTTP client (used by CLI)
  geoip/           ip-api.com client + ISO-from-name + ResolveHost +
                   CountryCentroid table  (NEW in rc12: hint.go)
  logx/            structured slog wrapper
  paths/           cross-platform data-dir resolver
  proto/           shared types — JSON tags = TS field names. Single
                   source of truth.
  rules/           routing rule engine (unused by current backend)
  single/          single-instance lockfile + named mutex (Windows)
  state/           Manager + Backend interface
                   - mock_backend.go
                   - singbox_backend.go    (real, default if exe found)
                   - sees ProxyListener via interface assertion
  store/           atomic JSON store (store.json under daemon dir)
  subs/            subscription parsers (4 formats)
ui/
  src/             React renderer
    api/             types.ts + client.ts (HTTP wrapper)
    components/      WorldMap, StatusSquare, ErrorBoundary,
                     locText, serverGroup, cityCoords
    screens/         Main (Atlas), Pool, Settings (basic), Splash
    styles/          atlas.css, app.css, pool.css
  src-tauri/       Rust shell
    binaries/        empty in tree; CI drops the side-loaded exes here
    icons/           .ico + .png, regenerated rc10 from user PNG
    src/main.rs      spawns mosaicd, parses lockfile, opens window
    tauri.conf.json  externalBin lists mosaicd + sing-box
.github/workflows/
  release.yml      Windows build pipeline; tag-triggered
docs/mockups/      original Atlas-aesthetic HTML mockups
README.md          full English user docs
README.ru.md       Russian mirror
HANDOFF.md         this file
```

## 5. What's done / not done

### Done as of rc20

**rc12 baseline:** daemon (HTTP API, single-instance lock, atomic
store, four subscription parsers, state machine, mock + sing-box
backends), sing-box config gen for VLESS/Hysteria2/Shadowsocks (Trojan
and VMess parsed but not wired), TCP latency probes, GeoIP via
ip-api.com with disk cache, host grouping in Pool/WorldMap with
clickable pins + "you" pin + copper arc, full Atlas-styled UI,
tag-triggered Windows release CI.

**rc13 — DNS / latency hijack fixes (`internal/api/server.go`,
`internal/geoip/hint.go`):**
- `probeServer` now resolves through 1.1.1.1 directly and dials the
  resolved IP, bypassing any system DNS hijack or transparent proxy.
  RTT is measured in microseconds (rc12 floor of 1ms produced fake
  "everything is 1ms" results).
- Debug log per probe with target / `RemoteAddr` / RTT, plus a warn
  when the dialled remote looks loopback / RFC1918 (catches future
  hijack regressions).
- `parseNaive` defaults port=443 when the URL omits it (fixed
  `np.zxc1x1.ru` host-grouping).
- Both `Test` API handlers skip `ResolveHost` / `resolveServerGeo`
  while `state == connected` so the active tunnel can't poison
  `ResolvedIP` for other hosts (fixed DE pin landing on VPS1).

**rc14 — map projection (`ui/src/components/WorldMap.tsx`,
`ui/src/styles/app.css`):**
- world.svg is now rendered as inline `<svg>` with its own viewBox
  `30.767 241.591 784.077 458.627`, `preserveAspectRatio="meet"`
  (rc17 changed from "none"). Pins live inside the same viewBox.
- Equirectangular projection fitted empirically to six country
  centroids (br, eg, in, is, mg, za) — residuals <10px.
- Latitude / longitude grid recomputed in the new system, clipped
  to the viewBox.

**rc15 — pin rendering & multi-host popover
(`ui/src/components/WorldMap.tsx`):**
- Pins replaced with teardrop SVG paths anchored at apex over the
  geo-point. Inner dot, with multi-host groups getting a slightly
  larger marker.
- Merge radius for nearby pins bumped from ~5px (rc12) to ~12 vb
  units / ~5° longitude.
- Multi-host pins show an Atlas-styled popover on click listing
  every member with `protocol:port  ms  [Connect]` rows; the active
  member is shown as `current` (disabled, copper).

**rc16 — clash-api stats & Atlas metrics
(`internal/state/singbox_backend.go`):**
- sing-box config gains `experimental.clash_api.external_controller`
  on a dedicated loopback port (preferred 9090, falls back to
  ephemeral) without a secret. Bound to 127.0.0.1 only.
- Two pollers run for the lifetime of a session:
  - `clashAPIPoll`: GET `/connections` once per second →
    `downloadTotal` / `uploadTotal` → `Status.bytes_in/_out`. 5s
    warm-up at 200ms cadence so the UI has data immediately.
  - `latencyPoll`: TCP probe of `ResolvedIP:Port` every 5s, RTT in
    microseconds, ResolvedIP via DNS-bypass.
- Both best-effort: errors logged at debug, previous value retained,
  connection unaffected. `Stop()` resets all three counters.
- UI: `fmtBytes(0)` renders "—" instead of "0 B" so Atlas doesn't
  look frozen pre-warm-up.

**rc17 — six fixes from user's 12-bug docket:**
- **#1 subscription proxy bypass** (`internal/api/server.go`,
  `internal/geoip/hint.go`): subscription fetch now uses an HTTP
  client with `Proxy: nil` and the bypass `DirectResolver` chain
  (1.1.1.1 → 8.8.8.8 → system fallback). It will succeed even when
  the active tunnel would otherwise loop the request through
  127.0.0.1:2080.
- **#3 default to proxy mode** (`internal/store/store.go`): default
  `Prefs.TunnelMode` flipped from `"tun"` to `"proxy"` for safe
  out-of-box (TUN requires admin + wintun.dll).
- **#5 horizontal map stretch** (`ui/src/styles/app.css`): map
  rendered inside an aspect-locked stage (784/459) with letterbox.
- **#6 last-server auto-reconnect** (`cmd/mosaicd/main.go`): on
  startup, if `Prefs.AutoConnect` is on and `LastServerID` is set,
  spawn a goroutine that connects after a 750ms warm-up. Best-effort,
  logs failures, daemon proceeds disconnected on error.
- **#10 user-supplied .ico** replaced everywhere (Tauri bundle, tray,
  splash). Original at
  `/home/ubuntu/attachments/2625912e-c90b-4cd1-b138-b42081076e23/ChatGPT+Image+Apr+28+2026+05_19_53+PM.ico`
  in dev VM (256×256, 70KB).
- **#11 clash-api diagnostics** (`SingBoxBackend`): logs
  `clash-api online {endpoint}` on first successful poll or
  `clash-api warm-up exceeded 5s` on timeout. Lets the user attach
  one log line if Atlas metrics still show "—".

**rc18 — admin gate, tray popup, agent skill:**
- **#4 TUN admin gate** (`ui/src-tauri/src/main.rs`,
  `ui/src/screens/Folio.tsx`, `ui/src/api/tauri.ts`): two new Tauri
  commands `is_admin` (Windows: `GetTokenInformation` with
  `TokenElevation`; Unix: `geteuid() == 0`) and `restart_as_admin`
  (Windows: `ShellExecuteExW` verb=runas, kills the bundled daemon
  first; non-Windows: error). When the user flips Folio → Network →
  Tunnel mode → TUN while unelevated, an Atlas-styled modal opens:
  "TUN requires administrator privileges" with Cancel / Restart-as-
  administrator buttons. Cancel reverts to proxy. Already elevated
  → modal never appears.
- **#9 tray popup** (`ui/src-tauri/src/main.rs`,
  `ui/src-tauri/tauri.conf.json`, `ui/src/App.tsx`): dedicated
  `tray-popup` window — frameless 360×500, `alwaysOnTop`,
  `skipTaskbar`, hidden by default, loads `index.html#/tray`. Tray
  left-click toggles visible/hidden via `toggle_tray_popup`,
  positioned just above the click point (fallback below if it would
  go off-screen). Blur listener auto-hides. Right-click tray menu
  unchanged: Show window / Hide window / sep / Quit Mosaic. The
  "Tray" tab in the main window is gone — it lives only behind the
  tray icon now. App.tsx detects `#/tray` and renders a slim shell
  (no Marginalia / TOC).
- **#8 agent skill** (`.agents/skills/mosaicvpn-dev/SKILL.md`):
  build commands, PR/tag conventions, test subscription URL,
  must-bypass-proxy invariant, file-by-file map.

**rc19 — pin redesign per user reference image
(`ui/src/components/WorldMap.tsx`, `ui/src/styles/app.css`):**
- Idle pins: outline diamond ~7vb radius + thin dashed stem to the
  geo-anchor.
- Active pin: copper teardrop with paper inner dot.
- "vous" marker: small ink dot + italic "vous" label, no box.
- Per-pin label boxes "City · ms" (paper text on ink, copper + bold
  for the active pin). Hover swaps both pin and label to copper.
- Connection lines: thin dashed paper curves from "vous" to every
  idle pin, drawn first; thick solid copper arc to the active pin
  drawn on top.
- Multi-host markers: small ink dot inside the diamond.

**rc20 — atomic process-tree shutdown + module rename:**
- **Job Object** (`ui/src-tauri/src/main.rs`, `mod job`): a single
  anonymous Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is
  created on first spawn. `mosaicd` is assigned to it, sing-box
  inherits the job from its parent (Win 8+ default). When the UI
  exits — clean OR hard (taskkill, OS shutdown, crash) — Windows
  closes the only handle to the job, the kernel terminates every
  assigned process. Solves "singboxes pile up after each launch".
- **Stale sing-box reaper** (`cmd/mosaicd/reap_windows.go`): at
  daemon startup, queries `wmic process where name='sing-box.exe'`,
  filters by command-line containing our `MOSAIC_DATA_DIR` /
  `singbox-current.json` path, and force-kills matches via
  `taskkill /T /F`. Handles upgrades from rc≤19 where stale
  sing-boxes are still around. No-op on non-Windows (`reap_other.go`).
- **Module path rename** `pupspochta-cpu/mosaicvpn → DangerousANEN/mosaicvpn`
  across every `.go`, `go.mod`, `go.sum`. Sed-and-rebuild; no
  functional change. Stack traces and `go install` paths now match
  the GitHub URL.

### Not done — known holes

| Area | Status | Where it lives / would live |
|---|---|---|
| TUN backend (wintun.dll, sing-box tun inbound, UAC) | NOT STARTED | `internal/state/singbox_backend.go` config gen |
| TUN stack selector (gvisor/system/mixed) | UI exists, ignored by backend | `Status.tunnel_mode`, `Prefs.tun_stack` |
| Kill-switch | UI toggle stored, ignored by backend | needs WFP / netsh logic |
| Bytes in/out | always 0 with sing-box | needs clash-api inside sing-box config + poller |
| Naive support | parser yes, backend no | `singbox_backend.outboundFor()` |
| AmneziaWG support | parser yes, backend no | external binary or sing-box wireguard |
| Trojan / VMess | parser yes, backend no | `singbox_backend.outboundFor()` |
| mosaicd as Windows service | NOT STARTED | golang.org/x/sys/windows/svc |
| Routing rules UI | engine done, no UI | `ui/src/screens/Rules.tsx` (doesn't exist) |
| System tray quick-connect / recents | minimal tray only | `ui/src-tauri/src/main.rs` |
| Auto-update | NOT STARTED | tauri-updater plugin available |
| Code signing | NOT STARTED | `release.yml` |
| MCP server | NOT STARTED | `internal/mcp/` (doesn't exist) |
| Subscription auto-refresh | field exists, no timer | `cmd/mosaicd/main.go` |

## 6. Known bugs — current state

### 6a. Original rc12 docket — all FIXED in rc13–rc16

The six bugs that originally lived here (latency hijack 1–2ms,
naive port=0 grouping, DE-via-VPS1 grouping, map projection,
Atlas metrics blank, pin shape + multi-host popover) are all
addressed. See §5 entries for rc13/14/15/16 for what was changed
and where.

### 6b. User's 12-point docket after rc16 — current state

Numbering matches the user's original list (sent in Russian).

| # | Bug | Status | Where |
|---|---|---|---|
| 1 | Subscription parser tries to go through proxy at 127.0.0.1:2080 even when the URL is reachable directly | **FIXED rc17** | `internal/api/server.go` (Proxy: nil + DirectResolver), `internal/geoip/hint.go` |
| 2 | TUN doesn't work even with administrator privileges | **NOT FIXED** — only the gating + UAC restart from rc18 ship; real TUN backend (wintun.dll bundle, sing-box `tun` inbound, route table) still pending | `internal/state/singbox_backend.go` config gen, `ui/src-tauri/tauri.conf.json` for wintun bundling, `cmd/mosaicd/main.go` for elevation detection |
| 3 | Default to proxy mode, not TUN, on first launch | **FIXED rc17** | `internal/store/store.go` |
| 4 | Pretty Atlas-styled prompt + "Restart as admin" button when a non-elevated user tries to enable TUN | **FIXED rc18** | `ui/src/screens/Folio.tsx` (`AdminGateModal`), `ui/src-tauri/src/main.rs` (`is_admin`, `restart_as_admin`) |
| 5 | Map stretched horizontally | **FIXED rc17** | `ui/src/styles/app.css` aspect-lock stage |
| 6 | Remember last server and auto-reconnect on launch / restart | **FIXED rc17** | `cmd/mosaicd/main.go` startup goroutine |
| 7 | Pretty pin design — make pins look hand-drawn / map-themed | **FIXED rc19** per user reference image (idle outline diamond + dashed stem, active copper teardrop, "vous" italic label, dashed paper / solid copper connection lines, per-pin "City · ms" labels) | `ui/src/components/WorldMap.tsx`, `ui/src/styles/app.css` |
| 8 | Agent skill for working with this repo | **FIXED rc18** | `.agents/skills/mosaicvpn-dev/SKILL.md` |
| 9 | Tray tab → tray icon popup window | **FIXED rc18** — frameless 360×500 popup window toggled by tray left-click; main-window "Tray" tab removed | `ui/src-tauri/src/main.rs` (`toggle_tray_popup`), `tauri.conf.json` (popup window), `ui/src/App.tsx` (slim shell at `#/tray`) |
| 10 | Replace icon with user-supplied .ico | **FIXED rc17** | `ui/src-tauri/icons/`, Tauri bundle |
| 11 | Atlas still doesn't show latency / down / up after rc16 | **DIAGNOSTICS ADDED rc17** — clash-api online / warm-up logs in `mosaicd.err.log`. If user reports the metrics still blank in rc17+, ask for that log line: it tells you whether the poller failed to bind, whether sing-box rejected the clash-api block, or whether sing-box itself never started | `internal/state/singbox_backend.go` |
| 12 | README redesign with screenshots / images | **NOT FIXED** — deferred until UI is locked. Should now be possible after rc20 since pin design / tray / admin-gate are stable | `README.md`, `README.ru.md` |

### 6c. Bug reported during rc20 cycle — FIXED in rc20

User: "singbox and mosaicd don't always close when I quit, multiple
singboxes can pile up". Fixed via Job Object on the UI side and
stale-process reaper at daemon startup. See §5 → rc20 for details.

### 6d. Stale-but-untouched holes (next agent: triage)

- Map pin geometry on the *original* `world.svg` (rc14/19 pins live
  inside the inline SVG with their own viewBox; if anything looks
  off it's the projection coefficients in `WorldMap.tsx`, not the
  rendering layer).
- Naive port-0 grouping is fixed in rc13 (`parseNaive` defaults to
  443) but the underlying naive backend in sing-box config gen
  still returns "naive proxy not yet supported by bundled
  sing-box" — see §7 of the original §5 hole table below.

### 6.1–6.6 (historical, kept for forensics)

Below is the original rc12 bug docket and the previous agent's
hypotheses. All six are fixed by rc13–rc16 (see §5 / §6a) but the
analysis is preserved in case the symptoms ever return.

### 6.1. Map pin geometry vs. world.svg is misaligned

- Symptom: pins drift off the country they should be in.
- Likely cause: the equirectangular projection assumes the SVG fills
  exactly the 1000×500 viewBox edge-to-edge. `world.svg` from
  AndrewSouthpaw/simple-world-map has built-in margins, so what the
  user sees rendered is a sub-rectangle of the SVG. Our projection
  formula `((lon + 180) / 360) * 1000` puts longitude=0 at x=500 of
  *our* viewBox, but in the rendered image lon=0 is somewhere around
  x=512-520 because the world starts ~10px in.
- Where: `ui/src/components/WorldMap.tsx:project()` and CSS in
  `ui/src/styles/app.css` (`.worldmap-img`, `.worldmap-pins`).
- Fix candidates:
  1. Open `ui/src/assets/world.svg` (or the imported one), find its
     real bounding box, and adjust the projection math (offset + scale)
     so lat/lon=0,0 lines up with the centroid of the rendered map.
  2. Or replace world.svg with a tighter equirectangular trace where
     lon=±180 / lat=±90 sit precisely on the 1000×500 edges.
  3. Easiest: render the map as an `<svg>` itself (not `<img>`) so
     pins live in the same viewBox as the continents; then offsets
     are guaranteed consistent.
- Test by dropping a known pin (e.g. lon=0, lat=0 → Gulf of Guinea)
  and a "you" pin currently at SVG (500, 290). Right now those don't
  agree visually.

### 6.2. Pin visual: ellipses → real pins, group nearby, context menu on click

- Symptom: pins are flat circles. User wants:
  - Real pin shape (teardrop / map-marker icon, not a dot)
  - Nearby pins collapse into one super-pin (we partially do this in
    `mergeNearbyPins` — threshold 5px viewBox units, ~0.5° on the
    map). User says it's not enough or not visible.
  - Click on a multi-host pin should open a *context menu* listing
    every host inside, with per-host Connect button.
- Where: `ui/src/components/WorldMap.tsx`. The `pinForGroup` already
  carries a full `ServerGroup` per pin and `mergeNearbyPins` merges
  members. The current click handler picks the primary member's id
  and connects directly; replace with a popover.
- Suggested approach:
  1. Replace the `<circle>` dot with an `<svg>` pin path: e.g.
     `M 0 0 C -7 -10, -7 -22, 0 -22 S 7 -10, 0 0 Z` filled with copper
     for active / paper-with-ink-stroke for idle. Drop the halo or
     keep as a soft glow.
  2. Replace `onClick={() => onPinClick(p.group.primary.id)}` with a
     state that toggles a popover; render a small Atlas-styled list
     of `{name, protocol:port, ms, [Connect]}` rows. Single-host pins
     can stay one-click.
  3. Bump merge threshold from 5px to ~12-15px so densely-packed
     datacenters merge more aggressively. The user explicitly asked
     for this.

### 6.3. Latency probes report 1–2 ms everywhere ("сломались задержки")

- Symptom: after `Test all`, every server shows 1ms or 2ms. The
  numbers used to be 144 / 155 / 163 ms in rc9–rc11.
- Likely root causes (untested — you must reproduce):
  1. **Probe goes through the local sing-box SOCKS listener.** If
     the user is currently `connected`, system-level TCP routing or
     a transparent proxy may be tunnelling all dials through
     127.0.0.1:2080. The SOCKS listener accepts TCP instantly →
     1-2ms RTT. Sing-box's HTTP inbound (127.0.0.1:2081) does the
     same. Verify with `tcpdump`/`wireshark` or by adding a debug
     log of the actual dial target.
  2. **DNS hijack.** If something on the host resolves all the test
     domains to 127.0.0.1 or LAN IPs (Pi-hole, Adguard, dnsmasq
     pointing at sing-box, …), the TCP probe terminates locally.
     Check what `geoip.ResolveHost` returns for one of the affected
     servers — if it's 127.0.0.1 or 192.168.x.x, that's the cause.
  3. **rc12 regression.** I do NOT believe rc12 changed `probeServer`
     itself, but I added `geoip.ResolveHost` calls AROUND it. Worth
     diffing rc11 vs rc12 of `internal/api/server.go` to be 100%
     sure I didn't introduce a side effect.
  4. **Floor.** `probeServer` returns `1` when `int(time.Since…)` is
     0 — but that floor was there in rc9 already, not new. Still
     worth checking the user is on rc12 and not stuck on a stale
     install.
- Where: `internal/api/server.go:probeServer()`. Add a debug-level
  log of `target` and `rtt` on every probe; ship a debug build to
  the user; have them run Test all and send `mosaicd.err.log`.

### 6.4. Atlas (main screen) doesn't show latency / down / up

- Symptom: user reports the metrics block on the Atlas screen is
  blank for `Latency`, `Down`, `Up` — even when connected.
- Where: `ui/src/screens/Main.tsx` lines around the `<Metric>`s.
- Likely cause: `Status.latency_ms`, `Status.bytes_in`,
  `Status.bytes_out` are all set to 0 by `internal/state/state.go`
  when running through `SingBoxBackend` — sing-box's stats endpoint
  isn't wired up. `latency_ms` was set by the (never-connected) mock
  backend; in real life nothing populates it.
- Fix candidates:
  1. **Bytes:** add a `clash-api` block to the generated sing-box
     config (`experimental.clash_api.external_controller`), poll
     `GET /connections` once per second from `mosaicd`, sum
     up/down deltas into store, and surface via Status.
  2. **Latency:** repeat the TCP probe against the active server
     every N seconds while connected. Or use sing-box's `urltest`
     outbound and read its measurements. Cheapest: re-probe
     `Server.Address:Port` directly every 5s.
  3. **As a stopgap until 1+2 are real:** show "—" instead of "0"
     when there's no data, so the user doesn't think it's "stuck"
     vs. "not implemented".

### 6.5. VPS1 + zxc1x1.ru should group together but don't

- Symptom: subscription has e.g. `VPS1-VLESS @ 206.251.50.217:10443`
  and `VPS1-Naive @ np.zxc1x1.ru:0`, both pointing at the same
  physical box, but rc12 puts them in different host groups.
- Likely cause:
  1. The naive entry has `port: 0` — `probeServer` fails fast on
     `dial tcp …:0`, never invokes the resolve flow successfully,
     so `ResolvedIP` stays empty. `groupServers` falls back to
     `address`, which is `np.zxc1x1.ru` ≠ `206.251.50.217`. Two
     groups.
  2. The naive parser may not extract the port at all (the original
     URL probably encodes it differently than the parser expects);
     see `internal/subs/`.
- Fix candidates:
  - Run DNS resolution unconditionally — even when the probe fails
    or port is 0 — so we have a `ResolvedIP` to group by.
    Currently `geoip.ResolveHost` is called *after* `probeServer`
    in the same handler; it should run regardless of probe success.
  - Or: add a separate `POST /v1/servers/{id}/resolve` that just
    does DNS without probing.
  - Fix the naive port-0 parser bug separately.

### 6.6. DE server gets grouped with VPS1 (wrong)

- Symptom: `DE-VLESS @ 206.251.50.217:18443` (which user says is a
  *different* physical box accessed via a VPS1 tunnel) ends up in
  the same host group as the actual VPS1 servers. Also the DE pin
  lands on top of VPS1 on the map.
- User's hypothesis (probably correct): "DE доступен через VPS1
  туннель" — i.e. when daemon resolves the DE address, the
  resolution / probe goes via an existing VPS1 connection, so DNS
  returns the VPS1 IP.
- This is the SAME root cause as 6.3.1 — once the daemon's network
  stack is partially tunnelled, every IP-resolution and TCP-dial
  collapses onto the tunnel exit.
- Fix candidates:
  1. **Don't auto-group by ResolvedIP when the address itself is an
     IP.** If `address` is already `206.251.50.217` for the actual
     VPS1, and `address` is also `206.251.50.217` for DE… then it's
     not a tunneling issue, the subscription is genuinely confusing.
     Verify what the original sub.txt actually says for DE.
  2. **Use the (address, resolved_ip) tuple rather than just
     resolved_ip.** Two different `address` values that resolve to
     the same IP only group if the *user* opts in.
  3. **Ground-truth DNS:** do the lookup with a custom DNS server
     (e.g. 1.1.1.1 directly, bypassing system DNS) so tunnel/local
     resolvers can't lie. Code change: pass a `Resolver` with
     `PreferGo: true` and a custom `Dial` to `internal/geoip/hint.go`.
  4. Also: the resolution may have happened while the user was
     still connected to VPS1 — purge any `ResolvedIP` set during a
     `connected` state, or never resolve while connected. Easiest
     guard: skip `ResolveHost` if `state.Manager.State() == connected`.

## 7. Building / running locally

```sh
# linux/macOS dev shell — builds mosaicd + UI, runs Tauri dev
./scripts/dev.sh

# windows
.\scripts\dev.ps1

# tests
go test ./...
cd ui && npm run build
```

`scripts/dev.sh` will fail gracefully if `sing-box` isn't on PATH —
the daemon falls back to MockBackend with a loud warning. To get
real connections you need a sing-box binary in PATH or next to
`mosaicd`.

To produce a Windows installer locally (needs Rust + Wix):
```pwsh
cd ui
npm ci
npm run tauri build
```

## 8. CI

`.github/workflows/release.yml` builds on Windows for any tag matching
`v*`. The job:

1. Builds `mosaicd.exe` (Go).
2. Downloads sing-box v1.10.7 official zip, extracts, places at
   `ui/src-tauri/binaries/sing-box-x86_64-pc-windows-msvc.exe`.
3. Builds `mosaic.exe` (CLI).
4. `npm ci && npm run tauri build` → installer.
5. Uploads `Mosaic_0.1.0_x64-setup.exe` as the run's artifact.

A typical end-to-end build is ~7-10 minutes. Use the artifact, not
the (currently empty) GitHub Releases page — releases haven't been
published, only tags.

## 9. Conventions the user expects

- **All commits via PRs into main.** Default branch is `main`. Old
  agent pushed feature branches and tagged from them — please open
  PRs from now on.
- **Don't merge your own PR.** User does that.
- **Don't force-push to main.** Don't amend. Add new commits.
- **Don't skip hooks.**
- **Tag every shippable build** as `v0.1.0-rcN` so the user can grab
  the installer from the Actions artifact.
- **Send the installer.** After CI finishes, `curl` the artifact zip
  and attach the `.exe` file to your `message_user`.
- **Always confirm scope before big features.** User repeatedly said
  "не правь, обсудим" — they expect a discussion turn before code.
- Never commit secrets. The user accidentally pasted a PAT once;
  don't repeat that.

## 10. Recommended next sprints

Plan as of rc20 (you can deviate, this is the framing the previous
agent discussed with the user):

| RC | Theme | Status |
|---|---|---|
| rc12 | host grouping + clickable pins + GeoIP fix | DONE |
| rc13 | DNS / latency hijack fixes (probe + naive port + skip-resolve-while-connected) | DONE |
| rc14 | Map projection (inline SVG + fitted equirect) | DONE |
| rc15 | Pin teardrops + multi-host popover | DONE |
| rc16 | clash-api stats + Atlas metrics | DONE |
| rc17 | sub-fetch bypass, default proxy, autoreconnect, icon, map letterbox | DONE |
| rc18 | TUN admin gate, tray popup, agent skill | DONE |
| rc19 | Pin redesign per user reference (idle diamond / active teardrop / vous / labels) | DONE |
| rc20 | Job Object atomic shutdown + stale-singbox reaper + module rename | DONE |
| **rc21** | **Real TUN backend** (wintun.dll bundle, UAC-aware sing-box `tun` inbound, route table) | NEXT — see notes |
| rc22 | Kill-switch (WFP rules) | 1 day |
| rc23 | mosaicd as Windows service so TUN doesn't UAC each Connect | 1 day |
| rc24 | Naive support (bundle naive.exe), Trojan/VMess in sing-box config | 0.5 day |
| rc25 | Routing rules UI | 1 day |
| rc26 | Auto-update + code signing | 1 day |
| later | README redesign with screenshots, MCP server, AmneziaWG bundling, recents in tray | — |

### Notes on rc21 (TUN backend)

The user has explicitly said "TUN doesn't work even with admin
privileges". The rc18 admin gate prevents non-elevated users from
even trying, but elevation alone is necessary, not sufficient. To
actually make TUN work:

1. **Bundle wintun.dll.** Add `wintun-amd64.dll` (and arm64 if you
   want to be future-proof) under `ui/src-tauri/binaries/` so the
   installer drops it next to mosaicd. sing-box loads wintun from
   the working directory by default.
2. **Generate a `tun` inbound** in `BuildSingBoxConfig` when
   `Status.tunnel_mode == "tun"`. Inbound type `"tun"` needs:
   `interface_name`, `inet4_address` (e.g. `172.19.0.1/30`), `mtu`
   (1500), `auto_route: true`, `strict_route: true`. See the
   sing-box wiki for the full schema.
3. **Pick a TUN stack.** sing-box exposes `gvisor` / `system` /
   `mixed`. `Prefs.tun_stack` exists in store but is currently
   ignored. `gvisor` is the lowest privilege requirement; `system`
   is fastest but needs a real-NIC bind. Default to `gvisor` until
   proven otherwise.
4. **Probe TUN readiness at startup.** If `tunnel_mode == "tun"`
   but the daemon is not elevated, refuse Connect with a clear
   error. The UI already gates the toggle in rc18; the daemon
   should also refuse so a stale prefs file can't surprise the
   user.
5. **Handle MOSAIC_DATA_DIR with TUN.** sing-box writes its own
   state (geoip cache, etc.) into the working directory. Our
   `cmd.Dir = b.dataDir` is fine; just verify nothing in the TUN
   inbound conflicts.
6. **Disable TUN from the popup tray window** as well as Folio so
   the user can flip it from anywhere.

The user runs Windows on `F:\aProgramms\Mosaic\` — they will need
to reinstall to pick up wintun.dll the first time. Make sure the
installer doesn't strip the DLL.

### What is **NOT** the next thing to do

- Don't touch the README until the user explicitly asks. They
  deferred #12 until UI lockdown; rc20 plus a TUN release should
  be enough lockdown to revisit.
- Don't refactor the WorldMap, Folio, or styles. The user has
  reviewed rc19 visuals and approved the direction.
- Don't add a fourth subscription parser variant. The four formats
  (sing-box, Clash, v2ray-b64, SIP008) cover everything they've
  shown us.

## 11. Useful one-shot snippets for the next agent

```sh
# Latest run for a tag
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/runs?per_page=10" \
  | python3 -c 'import sys,json; [print(r["id"], r["status"], r["conclusion"], r["head_branch"]) for r in json.load(sys.stdin)["workflow_runs"]]'

# Pull the installer artifact from a run id
RUN_ID=...
ART=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/runs/$RUN_ID/artifacts" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["artifacts"][0]["id"])')
curl -sL -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/artifacts/$ART/zip" -o art.zip
unzip -o art.zip
```

```pwsh
# Full clean reset on the user's Windows box
Get-Process mosaicd, mosaic-ui, sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force "$env:APPDATA\com.mosaicvpn.ui" -ErrorAction SilentlyContinue
# (then re-install)
```

```pwsh
# Diagnostic dump the user can paste back
Get-Content "$env:APPDATA\com.mosaicvpn.ui\daemon\mosaicd.err.log"
Get-Content "$env:APPDATA\com.mosaicvpn.ui\daemon\singbox.err.log"
Get-Content "$env:APPDATA\com.mosaicvpn.ui\daemon\singbox-current.json"
Get-Content "$env:APPDATA\com.mosaicvpn.ui\daemon\store.json"
```

## 12. What to message the user with first

The user is Russian. Reply in Russian, terse and technical. They
have explicitly granted "максимум автономно" — implement and ship
without per-PR confirmations. Only block on big architectural
decisions or when you genuinely cannot make progress.

Suggested opening (translate to Russian):

> "Прочитал HANDOFF, картина понятна. rc20 закрыл shutdown-баг
> (singbox/mosaicd больше не копятся — Job Object + reaper). Из 12
> пунктов твоего докета остались два: рабочий TUN (rc21) и README
> с картинками (rc26+). Беру TUN, план: …"

Then a 3-5 line plan for rc21 listing what you'll touch (wintun.dll
bundle in `ui/src-tauri/binaries`, `tun` inbound generation in
`BuildSingBoxConfig`, daemon-side admin check, `tun_stack` plumbed
through). Confirm before bundling wintun if you can't find a clean
license-compatible build.

### Things the previous agent learned the hard way

- The rc PR stack is intentional. Don't try to rebase it onto main
  yourself — the user merges in numeric order.
- `go test ./...` must be run after every Go change. If
  `TestSubscribeReceivesEvents` or another `internal/state` test
  fails as a flake on CI (TempDir cleanup race), retry the run via
  `POST .../actions/runs/<id>/rerun-failed-jobs`. Don't modify the
  test.
- Tauri CLI on Linux falls over on Rust `<1.85` (the `time` crate
  pulls `edition2024`). The Windows CI runner ships current Rust,
  so just trust CI rather than fighting local builds.
- Always download the artifact zip from the latest run and attach
  the `Mosaic_0.1.0_x64-setup.exe` to your `message_user`. The user
  doesn't browse GitHub Actions.
- Don't merge your own PRs. Don't amend. Don't force-push to main.
  These are explicit constraints from the user.

— rc20 agent, signing off.
— rc12 agent, signing off (original handoff preserved above).

---

## 11. rc21 → rc23 cycle (post-rc20 feedback)

After rc20 the user reported five new issues, then five more after
rc21, then nine more after rc22. Cycle summary:

### rc21 (PR #12, tag `v0.1.0-rc21`)

- Real TUN backend: bundled `wintun.dll` v0.14.1 via Tauri 2
  `bundle.resources` and the release workflow's pre-build download
  step (`.github/workflows/release.yml` lines 73–93).
- `Prefs.TunStack` (gvisor default) added to `internal/store/store.go`
  with backfill in `Open()` so the Folio dropdown round-trips.
- `tunInbound()` in `internal/state/singbox_backend.go`: `mosaic0`
  interface, `172.19.0.1/30`, MTU 1500, `auto_route`, `strict_route`,
  stack from prefs.
- Daemon admin gate: `IsElevated()` / `internal/state/elevation_*.go`
  (Windows uses `GetTokenInformation TokenElevation`); refuses Connect
  with `tun:elevation_required` prefix when `tunnel_mode==tun` and
  not elevated.
- `internal/geoip/LookupBatch` (ip-api.com `/batch`, 100 IPs / req,
  ≤15 reqs/min). `handleTestAll` now resolves geo in batches.
- URL test: `internal/state/singbox_urltest.go` spins up an ephemeral
  sing-box SOCKS proxy and fetches `gstatic.com/generate_204` through
  it. Surfaced as a per-server "Verify" button in Pool.
- Graceful shutdown: UI emits POST `/v1/disconnect` before drop on
  exit; daemon Job Object still kills runaway children as a backstop.

### rc22 (PR #13, tag `v0.1.0-rc22`)

- `internal/state/wintun.go` — Tauri 2 NSIS bundles
  `bundle.resources` paths verbatim relative to install root, so the
  rc21 install layout is `<install>/binaries/wintun.dll` (not under
  `resources/`). Added that path to the search list and now log every
  searched path in the missing-DLL error.
- `ui/src/components/countryCluster.ts` (new): second-pass clusterer.
  When ≥3 distinct cities in same ISO country, collapse to a single
  centroid pin with `kind="country"`; otherwise pass through as host
  pins. Threshold = `COUNTRY_CLUSTER_THRESHOLD = 3`.
- `ui/src/components/WorldMap.tsx` refactored to render `WorldPin =
  HostPin | CountryCluster` from the clusterer output. Country pin
  popover lists up to 12 cities with per-city Connect.
- LAN share: `prefs.ShareLAN` toggle in Folio → Network. When true,
  socks-in/http-in inbounds bind on `0.0.0.0` instead of loopback
  (see `internal/state/singbox_backend.go`).
- Live polling: `Pool.tsx` and `Main.tsx` now run a 5 s `setInterval`
  reload while the document is visible.
- Map labels v1: cream-fill rectangles with a 6 px diamond marker
  via `::before`.

### rc23 (PR #14, tag `v0.1.0-rc23`) — current

User feedback after rc22 (in user's words, paraphrased):

1. **TUN/mixed mode broken — no internet through tunnel.** Daemon
   logs needed; user has not provided them yet. Likely root causes:
   sing-box failing to install wintun adapter, `auto_route` not
   programming the routing table, or DNS leak. Until logs come in
   this is unactionable — tell the user to share `mosaicd.log` and
   `sing-box.log` from `%APPDATA%\com.mosaicvpn.ui\daemon\`. **Not
   fixed in rc23.**
2. **Map v2 redesign:** dark continents (rc23 bumped opacity from 0.5
   to 0.92), bigger SVG diamonds (rc23 grew from 7 vb radius to 10),
   `vous` in dark-fill rectangle (was bare italic), labels positioned
   BELOW the geographic anchor (was above). All in
   `ui/src/styles/app.css` and `ui/src/components/WorldMap.tsx`.
3. **Default tunnel mode = proxy on existing installs.** Added a
   one-time v2 migration in `internal/store/store.go` `Open()`: if
   `state.Version < 2`, force `Prefs.TunnelMode = "proxy"` and bump
   to v2. New installs start at v2 so the migration is a no-op.
   `Default()` now sets Version=2 directly.
4. **Reconnect to LastServerID, not `servers[0]`.** Manager.Connect
   now treats empty `serverID` as "use LastServerID, falling back to
   first available". UI `Main.tsx` and `Tray.tsx` toggle now passes
   `""` after a disconnect so the daemon picks the right server. The
   store already persisted LastServerID via `RecordConnect`.
5. **Long subscription URLs overflow Pool page.** Added `min-width:
   0` to `.pool-head` and made the parent grid column
   `minmax(0, 1fr)`; flex children now collapse-to-ellipsis as the
   inner `.pool-src` already had `text-overflow: ellipsis`.

### What rc23 did NOT do (carry to rc24)

These items are user-requested but not yet shipped. Each has a
concrete starting point:

- **TUN debug** — blocked on user logs. After rc23 ships, the new
  wintun-missing error message lists every searched path; if it
  still fails, that text alone tells you where Tauri is dropping the
  DLL. If TUN starts but no internet flows: dump `route print` on
  Windows (look for `0.0.0.0/0` going through the wintun adapter), and
  check sing-box stderr for "auto_route failed" or DNS leak
  warnings. Likely fix in `tunInbound()` or DNS section of
  `BuildSingBoxConfig`.
- **Country pins only render from one subscription** — user has two
  subscriptions; only the test sub `206.251.50.217:8888/sub.txt`
  lights up countries. Hypothesis: the other subscription's servers
  have empty `country` field (geo lookup didn't run, or returned
  blank). Verify by inspecting `state.json` after a Refresh-all on
  the offending sub. If `country == ""`, fix is in
  `resolveServerGeoBatch` — currently skips servers whose
  `ResolvedIP` is empty, which is exactly the case for hostnames it
  couldn't resolve. Either add a fallback to `LookupHost` or accept
  the hostname as-is for countries that are obvious (US `*.amazon`,
  etc.).
- **Map zoom + pan** — user explicitly asked. Two paths:
  (a) `react-zoom-pan-pinch` wrapper around `.worldmap-stage`
  (smallest patch); (b) re-implement viewBox manipulation in
  `WorldMap.tsx` (most flexible). I recommend option (a) for rc24.
- **Live updates still need refresh in some screens** — the rc22
  poll covers Pool and Main but not Folio (subscription stats),
  Atlas, or Tray. Either add the same `setInterval(reload, 5000)` to
  the remaining screens, or wire all of them to `/v1/events` SSE.
  The cleanest move is a shared `useLiveServers()` hook that owns
  the SSE subscription + initial fetch.
- **Subscription preview cards with click-to-expand drill-down** —
  user wants Pool to render compact cards by default and open a
  detail screen with the full server list on click. Today Pool
  already has an "expand to show stations" toggle (`expanded` state),
  but the user wants it to be a separate route. Suggest a new screen
  `SubscriptionDetail.tsx` reachable via `?sub=<id>` with full table
  of servers, RTT, last test, Connect column.
- **LAN share auth** — currently the SOCKS/HTTP inbounds on
  `0.0.0.0` are unauthenticated. Add `prefs.ShareUser` /
  `prefs.SharePass` (already partially scaffolded — there's a
  `ShareAllow []string` field) and wire the sing-box `socks` /
  `http` inbound `users` array. Tauri-side toggle is straightforward
  in Folio.

### Cleanup the next agent should do

- Strip the trailing ` no-expiration` suffix from the saved
  `GITHUB_PAT` org secret if you re-save it. Existing code already
  strips with `${GITHUB_PAT%% *}` but a clean token avoids future
  surprises.
- Don't bother trying to merge any rc PRs yourself; the user will
  do it when they decide. They've been stacking rc PRs since rc12
  and explicitly want this workflow.
- Watch for state.json migration regressions — rc23 introduced
  Version=2 with a forced `tunnel_mode=proxy`. If the user later
  re-flips to TUN and you bump to Version=3 for some other reason,
  don't reset their TunnelMode again unless that's explicitly
  intended.

— rc23 agent, signing off.

---

## 12. rc24 → rc38 cycle (notes for the next agent)

The rc24-rc33 cycle is in `git log`; the §11 carry-over list (TUN
debug, country-pin geo gaps, live updates beyond Pool/Main, LAN
auth, subscription detail screen) was largely worked through.
The work that *dominated* rc34-rc38 is the world map renderer; if
you only read one section, read this one.

### rc34 — pixel-merge clustering at all levels

Dropped the `city` band from `level-based-clustering`; all
clustering now goes through the same hex-bin or pixel-merge
primitive.  Vous marker shrunk so it stops eating the centre of
the viewport at low zoom.  `levelCluster.ts` is the entry point.

### rc35 — atlas defects bingo

Half-dozen visual regressions: SVG `NaN` on division by zero
when no servers are visible, margin-top background hole, the
zoom indicator overlapping the active pin, SOCKS-mode controls
overlapping, speedtest 502.  See PR description for the file
list — small, targeted patches.

### rc36 — hex-bin grouping, atlas HUD, polish

User asked for the cluster algorithm to actually prevent
overlap.  Switched to a self-rolled hex-bin in `(lat, lon)`
space (`vbToAxial(x, y, R)`) with 5 zoom-bands.  Stable cluster
ID = `hex:${bandId}:${q},${r}`, no pixel-merge afterwards (hex
cells don't overlap by construction).

The HUD layer was created here: plate label / compass rose /
atlas legend / km scale-bar / zoom controls.  Lives in
`HudOverlay.tsx`, rendered **outside** `TransformWrapper` so it
never zooms with the camera.

Roman numerals capped at XII via `numerals.ts` (used by
Main/Pool/Routing/Tray).  Min Tauri window 1100x720.

### rc37 — atlas region renderer (continent / country / server)

User: hexes are abstract, can we go continents → countries →
servers like a real atlas, with choropleth fill and "terra
incognita" hatching for empty regions?  Yes.

- **`ui/src/data/countries-110m.json`** — Natural Earth 110m
  countries minified to ~150 KB raw / ~30 KB gzipped.  No
  d3-geo; we project through our own equirect `projectVB()`.
- **`ui/src/components/atlas/shapeStore.ts`** — lazy-cached
  country and continent SVG path strings, derived from the
  GeoJSON above.  `getCountryShapes()`, `getContinentShapes()`,
  `getCountryByIso(iso)`, `getContinentByCode(code)`.
- **`ui/src/components/cluster/zoomBands.ts`** — three bands:
  `continent` (scale < 1.8), `country` (1.8 ≤ scale < 5.5),
  `server` (≥ 5.5).  `pinScale` is per-band.
- **`ui/src/components/cluster/RegionClusterStrategy.ts`** —
  groups `ResolvedGroup[]` by continent, country or server
  depending on the active band; emits `Cluster` with `shapePath`
  set from `shapeStore`.

Pin badges (count circle + numeric) and the invisible hit-area
circle were removed from the SVG pin element; the `<g>` itself
is the pointer target via `pointer-events: bounding-box`.

Wheel zoom step 0.06 → 0.02 to stop deltaY spikes from jumping
multiple bands per scroll tick.

Popover identity changed to `seedServerId` (the first member's
primary server id) instead of `cluster.id`, so the popover
survives band-boundary crossings.

Min window bumped to **1350 × 860**.

Dead code removed: `levelCluster.ts`, `blob.ts`,
`HexClusterStrategy.ts`.

### rc38 — side-panel HUD, antimeridian split, projection re-cal

User feedback after rc37 was specific:

1. Pin badges still rendering (rc37 only removed the SVG hit
   circle, not the count badge).  **rc38: removed both.**
   Diamonds are now pure shapes: stroke + fill, no circle child,
   no inline number.
2. Tooltip / popover shouldn't float above the pin — they should
   live in the HUD.  **rc38: `.worldmap-sidepanel` — a fixed
   atlas card docked top-right of the worldmap stage.**  Holds
   one of: hover-card, click-popover, vous-card, idle hint.
   Priority: open popover > vous > hover > idle.  No anchor
   math, no counter-scaling, never overlaps the HUD or pins.
3. New continents don't align with `world.svg` — Russia
   overflows right, Chukotka leaks to the left edge.  **rc38:**
   - `splitAntimeridian()` in `shapeStore.ts` splits any
     polygon ring whose consecutive points jump > 180° lon.
     Russia / USA-Aleutians / Fiji / Antarctica no longer
     render as a horizontal stripe.  bbox computation likewise
     picks the largest sub-ring, not the wrap-spanning union.
   - Equirect projection re-calibrated:
     `LON_OFFSET=422.806, LON_SCALE=2.178,
      LAT_OFFSET=470.905, LAT_SCALE=2.548`.
     The rc35-rc37 hand-tuned constants put `lon=180` ~30 px
     past the right edge of the viewBox.
   - `world.svg` raster base layer **dropped**.  The country
     choropleth shapes are now THE base map.  Pins, country
     borders and continent silhouettes share `projectVB()`, so
     they co-register by construction.  No more "two
     non-aligned maps" problem.  The asset file is still on
     disk but unreferenced — safe to delete.
4. Two diamonds visibly inside each other in dense metros.
   **rc38: server-band pixel-grid merge.**  Multiple
   `ResolvedGroup`s whose pin centroids fall within the same
   on-screen cell collapse into one cluster.  Cell shrinks
   inversely with zoom (14 vb / `max(scale, 0.5)`) so deep zoom
   still separates individual hosts.

PR #29 / tag `v0.1.0-rc38`.  Stacked on PR #28 (rc37).  Neither
is merged yet — the user reviews and merges in their own time.

### Non-map work the user might still want

- TUN end-to-end is still flaky — see §11 carry-over.
- Live updates beyond Pool/Main — Folio/Atlas/Tray still need a
  shared `useLiveServers()` hook over `/v1/events` SSE.
- LAN-share user/pass auth wiring.
- README screenshots refresh — every map redesign invalidated
  the old screenshots, so README.md / README.ru.md are stale.

### Open questions for the next agent

- **rc37 vs rc38 stacking.**  rc38 PR base is `devin/...rc37...`
  (PR #28).  If the user merges rc37 first, fine.  If the user
  decides to drop rc37 in favour of going directly from rc36
  to rc38, you'll need to rebase rc38 onto main with the rc37
  commit folded in.
- **Should the world.svg asset be deleted?**  rc38 stopped
  importing it.  `ui/src/assets/world.svg` is still on disk.
  It's ~53 KB.  Either leave for nostalgia or delete in a
  follow-up cleanup commit; the user's call.
- **Country labels.**  rc37/rc38 do not draw country names on
  the map.  Hover/click puts them into the side panel only.
  If the user asks for inline labels, look at
  `CountryShape.centroid` (bbox-centre, fast & deterministic;
  not the polygon-centroid) and add a band-gated `<text>` layer
  inside `.worldmap-shapes`.

— rc38 agent, signing off.

---

## 13. rc39 → rc44 cycle (agent continuing here)

Shipped as a linear stack of branches, **none merged to main** — user
keeps merging by tag. Default pattern every rc: branch off the previous
rc branch, commit, push, open PR, create annotated tag
`v0.1.0-rcN`, `release.yml` builds the Windows installer and uploads it
as a release asset, attach the `Mosaic_0.1.0_x64-setup.exe` file to the
chat.

Current tip when you pick this up:
- rc43 branch: `devin/1777578693-rc43-mcp-server` (PR #34) → tagged
  `v0.1.0-rc43`. Contains the actual MCP server + SKILL.
- rc44 branch: `devin/1777579866-rc44` (NOT yet pushed, work in
  progress — see §13.7). Branched off rc43.

### 13.1 rc39 — monolithic continent paths, shape-level interaction

PR #30 (taken over by agent). B&W diamond pins, continent = single
path (no per-country sub-shapes at the continent zoom band),
shape-level hover/click (the entire country silhouette is the
hit target, not the label).

### 13.2 rc40 — HUD click-through, myLocation redesign

PR not numbered (tag `v0.1.0-rc40` only). Changes:
- `.worldmap-sidepanel` root got `pointer-events: none` so HUD no
  longer eats cursor hovers behind it.
- Zoom-control button in the country-band toolbar fixes to centre
  (accounts for `preserveAspectRatio` letterboxing).
- Compass rose removed from HUD.
- Legend rewritten for rc39 palette (graphite available / copper
  active / hatch terra-incognita / pin states).
- All map hard-coded hex values moved to CSS vars so light theme
  actually flips them.
- `vous` chip pinned tight to the dot (no scale drift).
- Server-band: pixel-merge ignores city/country, purely geometric.
- **`resolveMyLocation`** (`cmd/mosaicd/main.go`): long-running
  loop that *only* calls ip-api.com while disconnected, caches
  30 min, force-refreshes on `Connected → Disconnected` edge,
  drops the result if Connect happens during lookup. This
  fixed the regression where `myLocation` was getting overwritten
  by the egress server's IP on every url-test/connect.
- **Verify column** in SubscriptionDetail with per-server
  `last_url_test_ms / status / error`. Persisted on the server
  record via `store.RecordURLTest`.
- "Test all (URL)" → "Stop" when clicked again; AbortController
  cancels in-flight.

### 13.3 rc41 — vous + HUD flicker + Verify dash + live version

PR #32. Fixes:
- `resolveMyLocation` cascade: ip-api.com → ipapi.co → ipinfo.io,
  and persists the last-known good result so vous pin appears
  immediately on next launch.
- `.sidepanel-card` (not just root) got `pointer-events: none` —
  hover no longer flickers as cursor moves over the HUD card.
- Servers that never ran Verify show `—` instead of a ghost
  "fail" row in the Verify column.
- `UpdateBanner.tsx`: `CURRENT_VERSION` is now `__APP_VERSION__`
  from Vite define (wired up via `vite.config.ts`, read from
  `package.json`). Before this it was hardcoded `"v0.1.0-rc30"`
  so the banner always said "update available" starting rc31.

### 13.4 rc42 — configurable Verify URL + Anti-DPI prefs

PR #33. New Settings sections:
- **Verify**: `Prefs.URLTestEndpoint` (default
  `https://www.gstatic.com/generate_204`, options: GOOGLE,
  CLOUDFLARE, CUSTOM). Any 2xx/3xx counts as success (was
  only 200/204 before). Surfaces in `state.URLTestServer`.
- **Anti-DPI** — four overrides applied when building the
  sing-box outbound config:
  - `DPIFingerprint` (auto / chrome / firefox / safari / ios /
    android / edge / random) — overrides outbound `tls.utls`.
  - `DPIFragment` (off / 1-3 / 2-5 / 5-10) — TLS ClientHello
    fragmentation for SNI-based DPI.
  - `DPIMux` (off / auto / 4 / 8) — mux.cool multiplexing.
  - `DPIECH` (bool) — Encrypted Client Hello if server has it.
- Applied to both Connect and Verify probes.

### 13.5 rc43 — **real MCP server + agent SKILL**

PR #34. The critical discovery was that rc-prior `Prefs.MCP*`
fields existed but no actual server had ever been wired up.
This rc fixes that.

- **New package `internal/mcp/`** — JSON-RPC 2.0 over HTTP POST
  on `Prefs.MCPAddr` (default `127.0.0.1:8731`).
- Shares the api.Server bearer token; rebinds to loopback only.
- Writes **discovery file** `{DataDir}/mcp.json` containing
  `url`, `token`, `permission`, `confirm`, `version`, `pid`,
  `started` — the file the agent SKILL teaches the agent to
  read.
- 10 tools with `minPerm` gating:
  - read: `mosaic_status`, `mosaic_list_subscriptions`,
    `mosaic_list_servers`, `mosaic_get_prefs`
  - connect: `mosaic_connect`, `mosaic_disconnect`,
    `mosaic_url_test`, `mosaic_refresh_subscription`
  - full: `mosaic_add_subscription`, `mosaic_remove_subscription`
- `MCPConfirm=true` currently **blocks** destructive tools with a
  clear error ("disable confirm in Settings"). No SSE-to-renderer
  confirm flow yet — planned for when multi-egress needs it.
- `api.Server` exposes `Refresh`, `URLTestServer`,
  `KickGeoResolve` so MCP reuses the same paths as the HTTP API.
- `cmd/mosaicd/main.go` wires `mcp.Start(ctx)` after the API
  listener and defers shutdown.
- **`.agents/skills/mosaicvpn-mcp/SKILL.md`** — full agent
  playbook. Discovery, auth, handshake, every tool, typical
  scenarios, curl+jq example, troubleshooting.
- Tests in `internal/mcp/server_test.go` cover auth, initialize,
  tools/list scoping, tools/call, permission denied, discovery
  file.

### 13.6 rc44 — shipped

**Scope shipped in one PR (`devin/1777579866-rc44`):**

1. **Subscription-Userinfo + Pool quota badge.** v2board / marzban
   `Subscription-Userinfo` header is parsed at fetch time;
   `proto.Subscription` carries `TrafficUsed`, `TrafficTotal`,
   `ExpiresAt`. Pool cards show a `SubscriptionQuota` strip with
   used / total bytes, a percentage bar, and an ISO-date expiry
   chip. Tone follows `subStatus`: yellow when ≥80% or expiring
   within 7 days; red when ≥95% or already expired.

2. **Recent-5 picker.** `proto.Server` gained `LastConnectedAt`;
   `state.Manager.Connect` calls `store.RecordConnect(serverID)`
   on a successful tunnel (state.go). Tray panel sorts by
   `last_connected_at` desc; if fewer than 5 servers ever
   connected, fills the rest with best-latency tested stations.

3. **Copy URI on server rows.** `SubscriptionDetail.tsx` shows a
   Copy-URI button per row. URI comes from `raw.uri` (preserved
   at parse time for v2ray-style sources) or is regenerated via
   `serverToURI(srv)`.

4. **Multi-egress subsystem.** Long-lived auxiliary SOCKS5 /
   HTTP proxies independent of the main Connect/Disconnect:
   - `proto.EgressConfig` + `proto.EgressStatus`.
   - `store.AddEgress / UpdateEgress / DeleteEgress / FindEgress`
     on `State.Egresses`.
   - **`internal/egress/manager.go`** — Manager type with
     `Start / Stop / Status / ListStatus / AutoStartAll /
     StopAll`; spawns one sing-box subprocess per egress, with
     a per-egress runtime struct tracking pid + cancel + cmd +
     startedAt + lastError. Subprocess gets reaped via
     `reapAfterExit` goroutine.
   - **`internal/state/singbox_egress.go`** — `BuildEgressConfig`
     builds the per-egress sing-box config: one inbound (SOCKS5
     or HTTP, never TUN/clash-api), one outbound (the pinned
     server). Anti-DPI overrides apply. ShareLAN flips bind to
     0.0.0.0 with optional ShareUser/SharePass auth.
   - **HTTP API:** `GET /v1/egresses`, `POST /v1/egresses`,
     `PATCH /v1/egresses/{id}`, `DELETE /v1/egresses/{id}`,
     `POST /v1/egresses/{id}/start`, `POST .../stop`. Wired via
     `apiSrv.SetEgressManager(egMgr)` in `cmd/mosaicd/main.go`.
   - **MCP tools:** `mosaic_list_egresses` (read),
     `mosaic_start_egress` / `mosaic_stop_egress` (connect),
     `mosaic_add_egress` / `mosaic_remove_egress` (full).
   - **Folio UI:** new chapter **viii Egresses** with table view
     (Name, Server, Protocol, Listen address, State, actions),
     per-row Start/Stop/Edit/Delete, "+ New egress" form with
     server dropdown, port, protocol, share-LAN toggle, optional
     LAN user/pass, AutoStart toggle.
   - **AutoStart:** `egMgr.AutoStartAll(ctx)` runs once at daemon
     startup; egresses with `AutoStart=true` come up
     automatically without explicit `/start`.

5. **Naive + AmneziaWG outbound (real, not stub).**
   `internal/state/singbox_backend.go` — `outboundFor` now
   builds proper sing-box configs:
   - **Naive:** native sing-box `naive` outbound. Detects scheme
     (https / quic) from `raw.scheme` or the original URI;
     `network: tcp` for naive+https, `network: udp` for
     naive+quic. TLS on by default, SNI defaults to host.
   - **AmneziaWG:** sing-box `wireguard` outbound +
     `amnezia_wg_settings` sub-object. Accepts both flat clash
     keys (jc / jmin / jmax / s1 / s2 / h1..h4) and the nested
     sing-box JSON form. Reads `private_key` /
     `peer_public_key` / `pre_shared_key` / `mtu` /
     `local_address` / `reserved` from raw, with clash fallbacks
     (`private-key`, `public-key`, `ip` / `ipv6`).
   - Old "not yet supported" returns are gone. README + README.ru
     protocol matrix bumped to ✅.

6. **Agent integration docs.** Added user-facing
   [`docs/AGENTS-MCP.md`](../docs/AGENTS-MCP.md): how Claude
   Desktop / Cursor / Continue / any MCP client connects to the
   running Mosaic — discovery file, token, JSON-RPC endpoint,
   per-tool permission table, copy-paste config snippets,
   security notes, troubleshooting. Linked from README.md
   ("Agent integration (MCP)") and README.ru.md ("Подключение
   AI-агента (MCP)"). The pre-existing
   `.agents/skills/mosaicvpn-mcp/SKILL.md` stays as the
   **developer-agent** material; the new doc is for **end-user
   agents**.

**Skipped this round (deliberate):**
- New app icon — no design provided, and the box has no
  `cargo tauri` CLI to regenerate icon sizes. Existing
  `src-tauri/icons/*` carry over from rc43. Pickup the next time
  the user provides a base PNG.

**Files touched (rc44 cumulative):**
- `internal/proto/types.go` — `Server.LastConnectedAt`,
  `EgressConfig`, `EgressStatus`.
- `internal/store/store.go` — `State.Egresses`, egress CRUD,
  `RecordConnect`.
- `internal/state/state.go` — call `RecordConnect` after
  successful Connect.
- `internal/state/singbox_backend.go` — naive / amneziawg
  outbound builders; `firstNonEmpty` helper bumped to variadic.
- `internal/state/singbox_egress.go` *(new)* —
  `BuildEgressConfig`.
- `internal/egress/manager.go` *(new)* — Manager.
- `internal/api/server.go` — `EgressManager` interface,
  `SetEgressManager`, six egress endpoints.
- `internal/mcp/server.go` — `EgressIface`, `Egress` config
  field, six egress tools, `stringArg / intArg / boolArg` arg
  helpers.
- `cmd/mosaicd/main.go` — wire `egress.New`,
  `apiSrv.SetEgressManager`, `mcp.Config.Egress`,
  `egMgr.AutoStartAll`, `defer egMgr.StopAll`.
- `ui/src/api/types.ts` — `Server.last_connected_at`,
  `EgressConfig / EgressStatus / EgressDTO`.
- `ui/src/api/client.ts` — `listEgresses / addEgress /
  updateEgress / deleteEgress / startEgress / stopEgress`.
- `ui/src/screens/Tray.tsx` — Recent-5 by connection history.
- `ui/src/screens/Pool.tsx` — `SubscriptionQuota` component +
  pool-quota CSS.
- `ui/src/screens/SubscriptionDetail.tsx` — Copy-URI button +
  `serverToURI` helper.
- `ui/src/screens/Folio.tsx` — `EgressChapter` (viii) + chapter
  registration.
- `ui/src/styles/app.css` — `.folio-egress-*` styling.
- `docs/AGENTS-MCP.md` *(new)* — user-facing MCP guide.
- `README.md`, `README.ru.md` — Naive / AmneziaWG ✅; new "Agent
  integration (MCP)" / "Подключение AI-агента (MCP)" sections.

### 13.7 rc45 — shipped

**Scope shipped in one PR (`devin/1777640079-rc45`, stacked on rc44):**

User asked: "а как добавлять amnesiawg подписки? они же как файлы
вроде" — pre-rc45 the only entry point for AmneziaWG was an
HTTP-served Clash YAML or sing-box JSON.  AmneziaVPN providers
typically hand out either a `.conf` file (`[Interface]` / `[Peer]`)
or a `vpn://...` token.  rc45 closes that gap.

- **`internal/subs/wireguardconf.go`** *(new)* — wg-quick INI
  parser. Hand-rolled (no third-party INI dep). `[Interface]` and
  `[Peer]` sections; comments `#` / `;`; `key = value` split on
  first `=`. AmneziaWG obfuscation params (`Jc`, `Jmin`, `Jmax`,
  `S1`, `S2`, `H1`..`H4`) lifted from `[Interface]` straight into
  `Server.Raw` under their lowercase canonical names — outboundFor
  in `singbox_backend.go` already speaks both clash flat and
  sing-box nested forms, so they round-trip unchanged.
  `Address` may be CSV (`10.0.0.2/32, fd42::2/128`) → parsed into
  `local_address []any`. `Endpoint` parsed via `net.SplitHostPort`
  so IPv6 bracket form works.
- **`internal/subs/amnezia_vpn.go`** *(new)* — `vpn://...`
  parser. Format reverse-engineered from amnezia-client and the
  reference decoder at github.com/andr13/amnezia-config-decoder:
  `vpn://` prefix → strip → urlsafe-base64 (lenient padding) →
  4-byte big-endian length header → zlib-decompress → JSON.
  Handles two flavours of the JSON: (a) "full export" with
  `containers[].awg.last_config` (a verbatim wg-quick payload —
  routed through `ParseWireGuardConf`); (b) "API handle" with
  `api_endpoint` + `api_key` — surfaces a descriptive error
  pointing the user at the AmneziaVPN client's "unwrap once,
  paste .conf" flow instead of silently producing zero servers.
- **`internal/subs/parser.go`** — `Detect()` now returns
  `FormatAmneziaVPN` / `FormatWireGuardConf` (checked first
  because both can otherwise look base64-shaped or JSON-shaped).
  New `ParseWithName(subID, payload, name)` lets callers pass a
  filename-derived display name; `Parse` and `ParseAs` now
  delegate to a shared `parseWithName` helper.
- **`internal/proto/types.go`** — added `FormatWireGuardConf` and
  `FormatAmneziaVPN`.
- **`POST /v1/subscriptions/import`** *(new endpoint, `internal/api/server.go::handleImportSub`)*
  — accepts `{name, filename, content}`. Detects format on
  `content`, creates a Subscription with empty URL +
  `AutoRefresh=false` (no remote to re-poll), then re-parses with
  the assigned subscription ID and stores via
  `ReplaceServersFor`. Re-parse step is intentional — first
  `ParseWithName` run just to validate format/error; second to
  rekey servers under `sub.ID` so `Server.SubscriptionID` joins
  cleanly with `Subscription.ID`.
- **UI: Pool → Add subscription bar** — new **Import file…**
  button next to **Fetch**. Hidden `<input type="file"
  accept=".conf,.json,.yaml,.yml,.txt,...">` triggered via ref;
  reads via `File.text()` (no Tauri dialog plugin needed — the
  webview's FileReader is sufficient). On success the Pool auto-
  Test-alls the new subscription, same as URL-based add.
- **`README.md` / `README.ru.md`** — feature bullet, quick-start
  step, API reference table all updated with the new endpoint
  and accepted formats.
- **Tests** — `internal/subs/wireguardconf_test.go` covers
  `.conf` parse (full + minimal + missing-peer error),
  `SuggestNameFromFilename`, the round-trip
  `vpn://...` parser via an in-test encoder mirroring
  amnezia-client's `encode_config`, and the API-handle error
  path. `go test ./...` green.

**Files touched (rc45 cumulative):**

- *(new)* `internal/subs/wireguardconf.go`
- *(new)* `internal/subs/amnezia_vpn.go`
- *(new)* `internal/subs/wireguardconf_test.go`
- `internal/subs/parser.go`
- `internal/proto/types.go`
- `internal/api/server.go` (added `bytes` import,
  `handleImportSub`, route registration)
- `ui/src/api/client.ts` (added `importSubscription`)
- `ui/src/screens/Pool.tsx` (file input + Import file… button)
- `README.md`, `README.ru.md`
- `HANDOFF.md` (this section)

### 13.8 rc46 — bug-fix pass on rc45

User reported nine items after testing rc45.  rc46 closed seven of
them in a single PR (`devin/1777641257-rc46`, PR #37, stacked on
rc45).  The two remaining items (offline GeoIP, UDP probe) shipped
in rc47.

**Closed in rc46:**

1. **Folio `.folio-btn` / `.folio-btn-primary` checkboxes
   unstyled** — pre-rc46 these classes had zero CSS rules; the
   rc44 egress chapter introduced LAN-share / AutoStart checkboxes
   and three buttons that all fell through to raw browser default.
   Added the bordered "paper" button family (default / primary /
   danger) plus a custom 14×14 checkbox skin to
   `ui/src/styles/app.css`.
2. **`SubscriptionQuota` marks every server as `expired`** when
   the subscription doesn't expose a `Subscription-Userinfo`
   header.  Root cause: Go's `omitempty` does **not** drop a zero
   `time.Time`, so JSON encoded it as `"0001-01-01T00:00:00Z"`,
   which the renderer parsed as a date in year 1 → tone=err.
   Fix: filter the zero-time string in `SubscriptionQuota` (UI).
   The Go side could equally well use a custom marshaller; UI
   filter is the lower-risk change.
3. **Hysteria2 server duplication** — providers ship one URI for
   the TLS listener and another for the port-hopping variant
   (`?mport=20000-50000`).  Both URIs collapsed onto the same
   ID because `serverID()` only hashed `host:port:password` —
   the store kept whichever survived a `ReplaceServersFor`, and
   the UI's `activeServerId === server.id` check matched both.
   Fix: include the raw URI in the ID hash; mport now also
   round-trips into `Server.Raw` and the outbound builder emits
   `server_ports: ["start:end"]` for sing-box.
4. **UI shows two simultaneous connects** — same root cause as
   #3.  No additional code change needed once IDs are unique.
5. **`vpn.tgapp.dev` subscription parsing** — the URI list was
   parsed correctly, but `mport` / `alpn` were stored in `Raw`
   without flowing through to the outbound builder.  Now both
   are surfaced (`tls.alpn`, `server_ports`).
6. **Naive doesn't connect** — `singbox_backend.go:outboundFor`
   was forcing `network: "udp"` for `naive+quic://` URIs.
   sing-box's native naive outbound is TCP-only — `network` is a
   filter, not a transport switch — so this rejected the config.
   Removed the override; ALPN now passes through if set.
7. **Hysteria2 password bug** *(silently fixed during the rc46
   audit; previously surfaced as Verify / Speedtest "unexpected
   EOF")* — `parseHysteria2` stored only `u.User.Username()`
   (the part before `:`) and dropped the colon half.  Hysteria2
   uses the **entire userinfo blob** as a single auth token.
   Auth failed silently upstream and sing-box dropped the
   connection mid-handshake → downstream probes saw EOF.
   Fix: `password = u.User.String()` with fallback to
   Username-only for legacy URIs.

**Files touched (rc46):**

- `internal/subs/v2ray.go` (parseHysteria2 password / dedup /
  mport / alpn; parseNaive ID dedup)
- `internal/state/singbox_backend.go` (hysteria2 outbound
  `server_ports` + `tls.alpn`; naive outbound — drop bogus
  `network: udp`, pass through ALPN)
- `ui/src/screens/Pool.tsx` (`SubscriptionQuota` zero-time
  guard)
- `ui/src/styles/app.css` (`.folio-btn*` + checkbox skin)

### 13.9 rc47 — offline geo db + UDP probe for QUIC / WireGuard

Closes the two items deferred from rc46.

**Offline GeoIP (replaces ip-api.com round-trip on every probe).**
User (`johndoedal2`) lives behind a network where ip-api.com is
flaky / rate-limited / blocked; pins for the `vpn.tgapp.dev`
subscription weren't drawing because `geoip.LookupBatch` was
silently failing.

- *(new)* `internal/geoip/local.go` — wraps
  `oschwald/maxminddb-golang` (added to go.mod).  `LoadLocalDB`
  / `LookupLocal` / `HasLocalDB` against the MMDB.  The schema
  matches both MaxMind GeoLite2-City and db-ip.com City Lite —
  `country.iso_code`, `city.names.en`, `location.{latitude,
  longitude}`.
- `EnsureLocalDB(ctx, dataDir, logf)` is the orchestrator.
  Stat the file at `<DataDir>/geo/city.mmdb`; reload if
  it exists and is < 35 days old; otherwise download
  `https://download.db-ip.com/free/dbip-city-lite-YYYY-MM.mmdb.gz`
  for the current month, falling back through the previous two
  months if the URL isn't yet published.  Atomic write
  (`<dest>.part` → rename).  Long-deadline `http.Client` (no
  total timeout, just dial / TLS deadlines) — the existing 8 s
  client is fine for the JSON endpoint but trips on the ~50 MB
  download.  Failures are non-fatal; the package keeps using
  ip-api.com.
- `internal/geoip/geoip.go::Lookup` and `LookupBatch` try the
  local DB first.  In `LookupBatch` we only build the outbound
  HTTP body for hosts that missed the local DB, so a
  1 000-server feed served by the local DB pays zero ip-api
  roundtrips.
- `cmd/mosaicd/main.go` kicks `EnsureLocalDB` in a goroutine at
  startup (no blocking).
- License: db-ip.com City Lite is **CC-BY 4.0**.  The download
  log line includes the attribution string ("db-ip.com lite, CC-BY
  4.0") on first load so we satisfy the licence by acknowledging
  the source in the daemon log.  README does **not** yet have
  the attribution — add it before any public release outside
  the rc cycle.

**UDP probe for QUIC / WireGuard.**  TCP-probing UDP-only
protocols always failed because the listener simply isn't on TCP.

- `internal/api/server.go::probeServerNet` adds a UDP path for
  `ProtoHysteria2` and `ProtoAmneziaWG` (selected via the
  `probeNetworkFor` helper).  Sends a single zero byte, then
  reads with a deadline:
  - data back / EOF → RTT = elapsed wall time.
  - `ECONNREFUSED` (POSIX) / `WSAECONNREFUSED` (Windows) →
    kernel saw an ICMP unreachable → port closed → fail with
    `udp closed: …`.  `isConnRefused` substring-matches on the
    formatted error since both spellings normalise to
    "connection refused".
  - timeout / silence → "alive but silent" (typical for QUIC
    and WireGuard, which never reply to unauthenticated
    payloads).  Returns the timeout itself as RTT so the UI
    renders "alive" instead of "unreachable".
- Non-UDP protocols are unchanged; `probeServer` is now a thin
  wrapper that always picks `"tcp"`.

**Files touched (rc47):**

- *(new)* `internal/geoip/local.go`
- `internal/geoip/geoip.go` (local-first Lookup / LookupBatch)
- `cmd/mosaicd/main.go` (kick `EnsureLocalDB` async)
- `internal/api/server.go` (probeServerNet + UDP path +
  probeNetworkFor; both probe call-sites updated)
- `go.mod` / `go.sum` (added
  `github.com/oschwald/maxminddb-golang v1.13.1`,
  bumped `golang.org/x/sys` to v0.21.0)

### 13.10 Permanent learnings the next agent should NOT re-discover

- User (`johndoedal2`) expects Russian replies, ships features by
  testing a Windows installer, and merges PRs by tag-not-branch.
- Every rc PR is stacked on the previous one. Don't rebase to
  main — you'll drop the other rc PRs from the stack.
- `release.yml` is triggered by pushing `v0.1.0-rc*` annotated
  tags. No manual dispatch needed.
- `Mosaic_0.1.0_x64-setup.exe` is the file to attach to the user;
  they don't download `mosaic.exe` separately.
- `MOSAICVPN_GITHUB_TOKEN` env var is a fine-grained PAT. It
  **cannot create/update PRs via `git_pr` tool** — create PRs via
  raw `curl` to `/repos/.../pulls` with the Authorization
  header; update via `PATCH /repos/.../pulls/N`. Tested, works.
- `git push` must go through `https://x-access-token:$TOKEN@...`
  explicitly; the tool wrapper doesn't inject credentials.
- Pre-commit hooks are not yet set up in this repo; running
  `pre-commit run --all-files` is a no-op.
- The Go binary lives at `/usr/local/go/bin/go`, not in PATH by
  default. Always prefix: `export PATH=$PATH:/usr/local/go/bin`.
- **rc46 lesson — Go `omitempty` does NOT drop a zero `time.Time`.**
  Either guard the zero string in the renderer or write a custom
  MarshalJSON.  Bit me on `Subscription.ExpiresAt`.
- **rc46 lesson — `serverID(subID, "hy2", host, port, password)`
  is not enough for hysteria2.** Port-hopping variants and any
  protocol with meaningful query parameters need the **full raw
  URI** in the hash, otherwise the store dedups them and the UI
  marks both as the active connection at the same time.
- **rc46 lesson — Hysteria2's URI userinfo is a single auth
  token.**  `u.User.String()` not `u.User.Username()`.  The
  symptom is silent EOF on every probe / Verify / Speedtest
  through the proxy — sing-box auth fails and the upstream
  drops the conn mid-handshake.
- **rc46 lesson — sing-box's native `naive` outbound is
  TCP-only.**  `network` is a NetworkList **filter**, not a
  transport switch.  Don't set `"network": "udp"` for
  `naive+quic://`; sing-box rejects the config.
- **rc47 lesson — db-ip.com City Lite is the "free GeoLite2
  alternative" with no API key required.**  URL pattern:
  `https://download.db-ip.com/free/dbip-city-lite-YYYY-MM.mmdb.gz`.
  Schema (country.iso_code / city.names.en /
  location.{latitude, longitude}) is compatible with the MaxMind
  GeoLite2-City schema, so a single `oschwald/maxminddb-golang`
  reader handles both.  License is CC-BY 4.0 — credit the source
  in any public-facing copy.
- **rc47 lesson — `probeServer` must be protocol-aware.**  TCP
  probe is wrong for hysteria2 / amneziawg / wireguard — those
  servers don't listen on TCP at all.  Use `probeServerNet` with
  `udp` for those protocols and read with a deadline so the
  kernel can ICMP-back closed-port errors.

— rc47 agent, picking up from rc44 mid-cycle.  Closed rc44, then
rc45 (file-import for AmneziaWG), then rc46 (bug list of nine), then
rc47 (deferred items: offline geo + UDP probe).  Open issues that
the next agent should triage:

- **Naive subscription not personally tested** — the rc46 fix
  (drop `network: udp`) is correct per sing-box docs but I have
  no naive provider to verify against.  If user reports it still
  fails, grab `mosaicd.err.log` and check whether sing-box errors
  on schema validation vs. handshake.
- **Local geo DB attribution** — the daemon logs the CC-BY 4.0
  source on first load but there's no UI surface for it.  Should
  appear in Folio "About" chapter alongside the version banner.
- **TCP-probe fallback for protocols that listen on both** — if
  a hysteria2 server happens to also accept TCP/443 (some panels
  multiplex hy2 + sni-proxy on the same port), we currently only
  probe UDP.  Could be improved with a TCP pre-probe and
  fallback to UDP, but it's marginal.
- **Multi-egress UI polish** — rc44 added the chapter, rc46
  styled the buttons.  Empty-state copy ("No egresses yet —
  click + Add to create one") is currently the literal
  `.folio-empty` italic placeholder; could use a clearer
  illustration / inline help.

# rc48 — johndoedal2 bug list (six fixes, one PR)

Stacked on `devin/1777659415-rc47`. PR shipped as `devin/1777707247-rc48`.
Closes the user-reported pile that came in after the rc47 install — none of
them blocked the daemon, all of them blocked **trust in the daemon's UI**.

Fixes in this rc, in the order they're discoverable from the user's
report:

1. **MCP permission was effectively immutable** — the `Server` struct
   cached `perm Permission` and `confirm bool` at `Start()`, so flipping
   Settings → MCP from "connect" to "full" only took effect after a
   daemon restart. The `mcp.json` discovery file ALSO carried the stale
   value, so external agents (Claude, Cursor) inspecting it on launch
   saw the pre-restart permission. rc48 drops the cached fields and
   reads `store.Snapshot().Prefs.MCP*` live on every `tools/list` /
   `tools/call`. `internal/api/server.go` grew a `SetPrefsChangedHook`
   callback fired by `PUT /v1/prefs`; mosaicd wires it to
   `mcp.Server.RewriteDiscovery()` so the file is re-emitted with the
   live values whenever Settings change.

2. **Verify "unexpected EOF"** lacked the sing-box stderr tail the rc40
   fix was supposed to attach. Root cause was Windows file-handle
   buffering — `logFile.Sync()` had to fire before `readURLTestTail`
   could see anything. Added an explicit `flushLog()` helper called on
   every error path; on tail miss we now also surface the absolute log
   path (`%APPDATA%\…\daemon\singbox-urltest-<port>.log`) so the user
   can inspect the full log manually.

3. **Speedtest "unexpected EOF"** had the same opaque-error problem —
   no sing-box context attached. Added a `LogTailer` interface
   implemented by `SingBoxBackend.LogTail(n int)` that returns the
   trailing N bytes of `singbox.err.log`. `Manager.Speedtest` now
   decorates every dial / read failure with the live tail, mirroring
   what Verify does. New `Prefs.SpeedtestURL` lets users override the
   default Cloudflare 10 MB → 5 MB → 1 MB ladder when their ISP / region
   throttles the speed.cloudflare.com edge mid-download. UI: new
   "Speedtest URL override" Opt in the Verify chapter (where
   url_test_endpoint already lives — same family of options).

4. **Bypass list wasn't actually bypassing** — Folio's `BypassChapter`
   wrote `proto.Rule` entries to the store, but `BuildSingBoxConfig`
   threw `_` over the rules slice and built `route.rules` with only the
   DNS rules. Result: in TUN mode every "direct" rule the user added
   was silently ignored. rc48 plumbs `rules []proto.Rule` through
   `BuildSingBoxConfig`, filters by `Action=="direct" && Enabled`, and
   emits one sing-box rule per entry. **Plus** a hard-coded
   `SystemBypassDomains` list that always appears in `route.rules` —
   ip-api.com, ipapi.co, ipinfo.io, db-ip.com, 2ip.ru, 2ip.io,
   ifconfig.me, ifconfig.co, icanhazip.com, api.ipify.org. These are
   the hosts mosaicd uses to detect the user's home location, so they
   must dial direct even while the tunnel is up.

5. **myLocation = egress location** — fallout from #4. With
   geo-resolution hosts now plumbed through the system bypass at the
   sing-box level, a Connect that lands mid-lookup no longer hijacks
   the IP. Plus rc48 adds an offline path: if all of ip-api.com /
   ipapi.co / ipinfo.io fail (rate-limit, ISP block, captive portal),
   `tryOfflineMyLocation` hits api.ipify.org / ifconfig.me /
   icanhazip.com (all in `SystemBypassDomains`) for the public IP and
   geocodes it locally via `geoip.LookupLocal` against the rc47
   db-ip.com city DB. We also enrich every successful cascade response
   with a `LookupLocal` pass — db-ip.com tends to give finer-grained
   city data than ip-api.com's free tier, and crucially it can never
   be poisoned by a mid-lookup Connect. The "drop on Connected" guard
   stays as a belt-and-braces backstop in case sing-box fails to start
   or `BuildSingBoxConfig` returns an error before the bypass list is
   in effect.

6. **VOUS label drifted off the dot** — the chip was an absolute-
   positioned HTML div using `(YOU.x - MAP_VB.x) / MAP_VB.w * 100%`
   for `left`/`top`. The pin layer SVG uses
   `preserveAspectRatio="xMidYMid meet"`, which letterboxes the SVG
   inside its CSS box; HTML percentage-of-box ≠ viewBox-coord-of-pin
   when the container aspect doesn't match the viewBox aspect. Fix:
   move the label into the pin SVG as a `<text>` element under the
   same `<g transform="translate(YOU.x, YOU.y)">`. While there: swap
   the bare `<circle r=1.8>` "you" dot for a teardrop pin with a
   contrasting copper fill and a paper-coloured core, so the user can
   actually find themselves at any zoom level. The paint-order:
   stroke-fill on the label gives it a paper-coloured halo for
   readability over dark geography.

## rc48 permanent learnings

- **MCP permission flips need live reads.** Caching at `Start()` is
  technically faster but the user-perceptible cost is "had to restart
  the daemon to grant the LLM extra permission" — which loses trust in
  Settings entirely. Live `store.Snapshot()` reads cost microseconds
  and run at human-clickable cadence, so just do them.
- **`mcp.json` is documentation, not auth.** The file is consumed by
  external agents on startup. Auth gating happens in
  `Server.handleRPC`, which now reads live. Keep them in sync via the
  `SetPrefsChangedHook` callback so the file matches reality at all
  times.
- **`logFile.Sync()` before tail-read on Windows.** OS write cache
  delays kept the rc40 "attach singbox tail" feature silently broken
  for two RCs. Always flush before slurping a file you just wrote
  through a stdio pipe.
- **`route.rules` system bypass first, user rules after.** sing-box
  evaluates in order; the system bypass for geo-resolution hosts must
  come before any user rule that might accidentally proxy them. The
  hard-coded list is small (10 hosts) and well-defined (everything
  mosaicd or a curious user would hit to verify "is my IP leaking?"),
  so the policy is "bypass these, full stop, no user opt-out".
- **db-ip.com city lookups beat ip-api.com city.** The free tier of
  ip-api.com is rate-limited and gives a coarse city guess; db-ip.com
  Lite (already loaded for server-pin resolution) is sub-city in
  populated regions and never rate-limits. Enrich every result through
  the local DB when one is loaded.
- **HTML-overlay positioning over an SVG with `preserveAspectRatio`
  is a trap.** The viewBox-to-pixel mapping inside the SVG is **not**
  the same as percentage-of-bounding-box outside it whenever the SVG
  letterboxes. If a marker has to sit relative to an SVG point, render
  it inside the SVG.
- **`paint-order: stroke fill` + paper-coloured stroke is the cheap
  text-on-anything trick.** No need for a backing rect: render the
  stroke first (in the page background colour), then the fill on top.
  Works at every zoom and stays sharp.

Open hand-offs going into rc49:

- **TUN end-to-end stability** — still no reproducible "internet works
  through TUN tunnel" report from the user. The bypass-rules fix in
  this rc means at least the daemon's *own* probes survive TUN, but
  user-traffic round-trip needs `mosaicd.log` + `singbox.err.log`
  excerpt from a real Connect attempt to triage further.
- **Naive personal verification** — no provider available to me;
  rc46+rc47 fixes are theoretically correct.
- **db-ip.com attribution in About** — still TODO; daemon log carries
  it but Folio "About" chapter doesn't.
- **Live updates** — Pool/Main poll `/v1/events`; Folio/Atlas/Tray do
  not. A `useLiveServers()` hook would consolidate.
- **LAN share user/pass full plumbing** — rc44 added Prefs fields,
  sing-box inbound `users[]` array is wired (rc44), but UI flows for
  generating + displaying the credentials still need polish.

— rc48 agent.
