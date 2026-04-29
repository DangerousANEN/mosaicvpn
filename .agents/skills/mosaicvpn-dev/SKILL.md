# MosaicVPN — agent skill

Reference notes for any agent picking this repo up.

## What this is

Desktop VPN client for Windows. Three pieces:

- `mosaic-ui` (Tauri 2 shell, Rust) — `ui/src-tauri/`. Spawns the daemon
  as a child, draws the system tray, holds the webview.
- `mosaic-ui` renderer (React + Vite + TypeScript) — `ui/src/`. The
  Atlas-style UI the user actually sees.
- `mosaicd` (Go daemon) — `cmd/mosaicd/`, with the bulk of the logic in
  `internal/`. Exposes a localhost-only HTTP API (port allocated at
  startup, written to `daemon.lock` along with a bearer token) and
  drives the bundled `sing-box.exe` as a child of its own.

Module path: `github.com/DangerousANEN/mosaicvpn`.

## Roadmap & history

- `HANDOFF.md` in repo root has the full design log and the §6 bug
  docket the user reports against. **Read it first.**
- Releases are tagged `v0.1.0-rcN`. Each rc is a single PR into
  `main`. PRs are stacked: rc14 is on top of rc13, etc., until the
  user merges them all into main. **Don't merge your own PRs.**
- Each PR description has a "Review & Testing Checklist for Human"
  section the user actually runs through.

## Build / test

```
# Go (from repo root)
go build ./...
go test ./...

# UI
cd ui
npm run lint
npm run build         # tsc + vite

# Tauri release build is done in CI only — release.yml on tag push.
```

The Tauri shell only starts cleanly with the bundled `mosaicd.exe`
present, so local end-to-end testing on Linux is limited to running
`go test ./...` and the renderer's vite dev server.

## CI / shipping flow

1. Push a feature branch to GitHub.
2. Open a PR into `main` via the `git_pr` tool.
   `git_pr(action="fetch_template")` first — the create action
   requires a fetched template. Default PR description includes
   `## Summary` and `## Review & Testing Checklist for Human`.
3. Wait for CI: `git(action="pr_checks", wait_mode="all")`.
4. Tag `v0.1.0-rcN` (annotated, not lightweight) and push the tag.
   `release.yml` builds the Tauri installer in ~7 min.
5. Download the artifact and attach the `.exe` to `message_user`:
   ```
   ART=$(curl -s -H "Authorization: token $GITHUB_PAT" \
     "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/runs/$RUN_ID/artifacts" \
     | jq -r '.artifacts[0].id')
   curl -sL -H "Authorization: token $GITHUB_PAT" \
     "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/artifacts/$ART/zip" \
     -o /tmp/mosaic.zip
   unzip -o /tmp/mosaic.zip -d /tmp/rcN/
   # Mosaic_0.1.0_x64-setup.exe is what the user installs.
   ```

## Conventions

- All commits go through PRs. The `git` tool refuses pushes to `main`.
- Don't amend, squash or force-push. Add new commits to fix issues.
- Never skip pre-commit hooks.
- Branches: `devin/<unix-ts>-<slug>` (the timestamp keeps multiple
  in-flight branches sortable and avoids name collisions).
- Tags: annotated `v0.1.0-rcN`, message = first line of PR title.
- Don't commit secrets. The daemon's bearer token is generated at
  startup and written to `daemon.lock`; never log it.

## Test resources

- Test subscription: `http://206.251.50.217:8888/sub.txt`. **Test only,
  not Connect.** Some servers in this list will break if you push real
  traffic through them.
- Daemon data dir on Windows: `%APPDATA%\com.mosaicvpn.ui\daemon\`.
- `mosaicd.err.log` and `singbox.err.log` are the two logs to grep
  when something doesn't work end-to-end.

## Communication

- The user is Russian-speaking. Reply in Russian; keep technical
  terms in English (`probe`, `clash-api`, `merge radius`, `pin`).
- Terse and technical. No padding. No "Let me…" / "I'll help…".
- "не правь, обсудим" → don't code, discuss the plan first message.
- "максимум автономно" → user is going AFK, push through everything
  on the docket without blocking.

## Key code touchpoints

| Concern                              | Where                                                |
| ------------------------------------ | ---------------------------------------------------- |
| HTTP API surface                     | `internal/api/server.go`                             |
| sing-box config + child process      | `internal/state/singbox_backend.go`                  |
| State machine, prefs, persistence    | `internal/state/state.go`, `internal/store/store.go` |
| Subscription parsers (vmess, vless,  | `internal/subs/`                                     |
| trojan, hy2, ss, naive, sing-box)    |                                                      |
| Probe + DNS bypass                   | `internal/api/server.go` `probeServer`,              |
|                                      | `internal/geoip/hint.go` `DirectResolver`            |
| GeoIP lookup (ip-api.com, no-proxy)  | `internal/geoip/geoip.go`                            |
| World map (renderer + HUD + side panel) | `ui/src/components/WorldMap.tsx`                   |
| World map projection (equirect)      | `ui/src/components/cluster/resolveGroups.ts` —       |
|                                      | `projectVB()`, `LON_OFFSET / SCALE`, `LAT_*`         |
| Region cluster strategy              | `ui/src/components/cluster/RegionClusterStrategy.ts` |
| GeoJSON country / continent shapes   | `ui/src/components/atlas/shapeStore.ts`,             |
|                                      | `ui/src/data/countries-110m.json` (Natural Earth)    |
| Zoom bands (continent/country/server)| `ui/src/components/cluster/zoomBands.ts`             |
| Atlas HUD overlay (compass, legend)  | `ui/src/components/HudOverlay.tsx`                   |
| Roman-numeral cap                    | `ui/src/components/numerals.ts`                      |
| Tauri shell (tray, window, daemon)   | `ui/src-tauri/src/main.rs`                           |

## Outbound HTTP — must bypass proxy

mosaicd's *own* outbound HTTP calls (subscription fetch, GeoIP,
clash-api poll) must use clients with `Proxy: nil` and a
`net.Dialer{Resolver: geoip.DirectResolver()}`. Otherwise:

- `HTTP_PROXY` env vars or the Windows system proxy can redirect
  subscription fetches through sing-box's loopback SOCKS — which is
  itself proxying *for* the user, leaving us with a deadlock.
- A hijacked OS resolver (corporate DNS, ad-block, captive portal)
  poisons `Server.ResolvedIP` and breaks the Test path's RTT readings.

Helpers: `directHTTPClient()` in `internal/api/server.go`,
`httpClient()` in `internal/geoip/geoip.go`. Use them, don't hand-roll
new ones.

## Tauri quirks

- `ui/src-tauri/Cargo.toml` Tauri features: `tray-icon`, `devtools`.
- Icons live in `ui/src-tauri/icons/`; replace **all** of
  `icon.{ico,png}`, `32x32.png`, `128x128.png`, `128x128@2x.png`,
  `Square150x150Logo.png`, `Square30x30Logo.png` together. Multi-size
  `.ico` should contain 16/24/32/48/64/128/256.
- The shell spawns `mosaicd.exe` as a child and kills it on exit;
  don't add a separate spawn path or you'll race the lockfile.
- `MOSAIC_DATA_DIR` env var overrides the per-OS data dir for both
  the shell and the daemon — use it in dev to point at a sandbox.

## World map architecture (rc38)

The map went through several rewrites; the current shape, as of
rc38:

- **Projection** — equirectangular, projected by
  `projectVB(lat, lon)` in `cluster/resolveGroups.ts`.
  `LON_OFFSET=422.806, LON_SCALE=2.178,
   LAT_OFFSET=470.905, LAT_SCALE=2.548`.
  Maps `[-180,180] × [-90,90]` cleanly onto the world.svg viewBox
  `(30.767, 241.591, 784.077, 458.627)`.  Pins, country borders
  and continent silhouettes all share this projection so they
  co-register by construction.
- **Base layer** — country shapes from
  `ui/src/data/countries-110m.json` (Natural Earth 110m, ~150 KB
  raw / ~30 KB gzipped).  No d3-geo.  `world.svg` is dropped from
  the render but the asset still ships in the repo.
- **Antimeridian** — `shapeStore.splitAntimeridian()` splits any
  polygon ring whose consecutive points jump > 180° lon, so
  Russia / USA-Aleutians / Fiji / Antarctica don't render as a
  horizontal stripe across the whole map.
- **Cluster strategy** — `RegionClusterStrategy` (no more hexes).
  Three zoom bands defined in `cluster/zoomBands.ts`:
  `continent` (scale < 1.8), `country` (1.8 ≤ scale < 5.5),
  `server` (≥ 5.5).  At server band, ResolvedGroups are merged
  into one cluster per pixel-grid cell so dense metros don't
  show overlapping diamonds.
- **Pin** — pure diamond.  No badge circle, no count text, no
  hidden hit-area circle.  Hit target is the `<g>` element via
  `pointer-events: bounding-box`.
- **HUD** — `HudOverlay.tsx` renders compass / legend /
  scale-bar / plate label / zoom controls **outside**
  `TransformWrapper`, so it never zooms with the camera.
- **Side panel** — `.worldmap-sidepanel`, fixed atlas card
  docked top-right of the worldmap stage.  Holds one of:
  click-popover, vous-card, hover preview, idle hint.  Priority
  popover > vous > hover > idle.  No anchor math, no
  counter-scaling, never opens off-screen.  This replaces the
  rc35-rc37 floating tooltip / popover that used screen-space
  anchor coords.
- **Popover identity** — a popover is keyed on `seedServerId`
  (the first member's primary server id), not `cluster.id`, so
  it survives band transitions without vanishing.
- **Min Tauri window** — 1350 × 860 (set in
  `ui/src-tauri/tauri.conf.json`).  Don't shrink below this; the
  HUD layout assumes that envelope.

If the user reports "two non-aligned maps", "Russia overflows",
"countries shifted", or "pins not on continents", you almost
always want to look at `projectVB()` constants and
`splitAntimeridian` in `shapeStore.ts` — the choropleth shapes
and the pins share the same projection so any drift means the
constants are off.
