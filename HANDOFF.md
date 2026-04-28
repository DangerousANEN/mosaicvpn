# Handoff — MosaicVPN

> This document is written FOR the next coding agent picking up the
> project. It is not user-facing documentation — see `README.md` /
> `README.ru.md` for that. Read this top-to-bottom before touching any
> code; it captures everything the previous agent learned so you don't
> have to re-discover it.

Last updated: rc12 shipped. Currently blocked on six known bugs (see §6).

---

## 1. Repo & owner facts

- GitHub: <https://github.com/DangerousANEN/mosaicvpn>
- Default branch: `main`
- Live tags so far: `v0.1.0-rc2` … `v0.1.0-rc12` (each tag triggers a
  Windows build via `.github/workflows/release.yml` and uploads
  `Mosaic_0.1.0_x64-setup.exe` as an artifact).
- Open PRs: PR #1 = rc12 → main (devin/1777375850-rc12-grouping). User
  hasn't merged yet; the rc12 build was tagged from the branch tip
  before the PR landed.
- Old per-rc feature branches were cleaned up; only `main` remains.
- Module path: `github.com/pupspochta-cpu/mosaicvpn` (note: the GitHub
  org is `DangerousANEN`, the Go module path uses `pupspochta-cpu`
  from earlier history — do NOT change this without coordinating, all
  imports use the latter).

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

### Done as of rc12

- Daemon: HTTP API surface, single-instance enforcement, lockfile w/
  bearer token, store with atomic writes, subscription parsers (4
  formats), state machine, mock backend, sing-box backend.
- Sing-box backend (`internal/state/singbox_backend.go`) supports:
  VLESS + TLS / Reality + ws/grpc/xhttp transports, Hysteria2 with
  optional `obfs=salamander`, Shadowsocks (all sing-box AEAD ciphers).
  Naive and AmneziaWG return errors. Trojan / VMess parsed but NOT
  wired into config gen.
- TCP latency probes via `POST /v1/servers/{id}/test` and
  `POST /v1/servers/test-all` (16-way concurrent).
- GeoIP via `ip-api.com` (free, 45 req/min). Cached lat/lon in store.
- rc12: ResolveHost (DNS lookup to ResolvedIP), IsoFromName (ISO-2
  from server display name), CountryCentroid fallback, host grouping
  in Pool + WorldMap, clickable pins with hover tooltip, "you" pin
  at center, copper arc to active.
- Frontend: full Atlas-styled UI (Main / Pool / Settings / Splash),
  ErrorBoundary, working scrollbars, location separated from name
  (rc11), per-host grouping (rc12).
- CI: tag-triggered Windows build, ships installer with sing-box
  bundled. Icons regenerated rc10 with Lanczos + unsharp.
- Documentation: bilingual README, this handoff file.

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

## 6. Known bugs (rc12 user feedback) — START HERE

These are the active blockers. **Read each carefully — there are
hypotheses and pointers, but the previous agent did NOT verify the
fixes; do your own investigation before believing my guesses.**

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

The previous agent's plan (you can deviate, but it's the framing that
was discussed with the user):

| RC | Theme | Effort |
|---|---|---|
| rc12 | host grouping + clickable pins + GeoIP fix | DONE — but see §6 bugs |
| rc13a | Fix the six rc12 bugs in §6 | half day |
| rc13b | Real TUN backend (wintun.dll, UAC, sing-box tun inbound) | 1 day |
| rc14 | Kill-switch (WFP rules) + bytes via clash-api | 1 day |
| rc15 | mosaicd as Windows service so TUN doesn't UAC each Connect | 1 day |
| rc16 | Naive support (bundle naive.exe), Trojan/VMess in sing-box config | 0.5 day |
| rc17 | Routing rules UI | 1 day |
| rc18 | Auto-update + code signing | 1 day |
| later | MCP server, AmneziaWG bundling, recents in tray | — |

**My strong suggestion:** start with rc13a (fix §6 bugs) before
touching TUN. The user will not be able to evaluate TUN if they can't
trust that the map / latencies / grouping are correct.

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

Suggested opening (translate to Russian):

> "Прочитал HANDOFF, картина понятна. Сначала фикшу шесть багов rc12
> из §6 (карта, лагающие пинги, группировка, метрики Atlas), потом
> возьмусь за TUN. Прежде чем коммитить — короткий план: …"

Then list which of the six bugs you'll attack first and why. Don't
start TUN until rc12 issues are resolved.

— previous agent, signing off.
