# Mosaic VPN — onboarding prompt for the rc28 agent

You are picking up the Mosaic VPN release cycle from the rc27 agent. Read
`HANDOFF.md` first for the long-form architecture / build / TUN / GeoIP
context — it is still 100% accurate. This file is the *delta* covering
rc24 → rc27 plus exactly what's left for you (rc28).

---

## 1. Repo & workflow facts (unchanged from rc23)

- **GitHub:** https://github.com/DangerousANEN/mosaicvpn
- **Base PR branch:** `devin/1777403083-rc23-feedback` (PR #14, all rc24+
  go INTO this branch, not into `main`).
- **Current branch:** `devin/1777411409-rc27` (committed code waiting for
  PR creation when you read this — see §3).
- **Latest tag shipped:** `v0.1.0-rc26`.
- **CI:** GitHub Actions builds `Mosaic_0.1.0_x64-setup.exe` in ~7–10 min
  per tag push under the `mosaic-windows-installer` artifact.
- **`GITHUB_PAT`** is stored with a `" no-expiration"` suffix in its
  value — strip it before use:

  ```sh
  PAT="${GITHUB_PAT%% *}"
  curl -H "Authorization: Bearer $PAT" ...
  ```

- **Git author identity is auto-set; do not run `git config`.**
- **Don't force-push, amend, or merge your own PRs.**

## 2. User context (read this before replying)

- Russian, Windows user. Reply terse, technical, in Russian.
- Granted "максимум автономно" — ship rc28 without per-PR confirmations.
  Block ONLY on architectural questions or genuinely missing info.
- All UX must be **in-app**. No `window.prompt`, no system dialogs.
- Tests on real Windows after each .exe; logs at
  `%APPDATA%\com.mosaicvpn.ui\daemon\` (`mosaicd.err.log`,
  `singbox.err.log`, `singbox-current.json`).

## 3. What rc24 → rc27 actually changed

### rc24 (shipped, tag v0.1.0-rc24)
- Country-pin DNS fallback (resolves hosts before ip-api batch so
  newly-added subscriptions don't show 0 pins).
- Map zoom/pan via react-zoom-pan-pinch, double-click reset.
- SubscriptionDetail screen on `#sub=<id>` route.
- `useLiveServers` 5s poll hook. Tray now live.
- LAN share auth via `Prefs.ShareUser`/`ShareePass`, plumbed into
  socks/http inbound `users[]`.

### rc25 (shipped, tag v0.1.0-rc25)
- **TUN DNS fix v1**: added `dns:` block to sing-box config. (Did not
  fully fix; see rc26.)
- **Pin regression fix**: background geo-resolve after add/refresh; 16-
  way concurrent ResolveHost. Subscribed-while-connected now shows
  pins eventually.
- **Verify port fix**: `pickPort(0)` was returning literal 0.
- **LAN listener actual address**: real LAN IP + ephemeral port reported
  in `/v1/status`, displayed in Folio → Network.
- Map zoom step 0.15 → 0.05.
- Pool: "Browse stations" → "Servers"; in-app Edit (renamed away from
  prompt() in rc26).
- SubscriptionDetail: "Test all (TCP)" + "Test all (URL)" buttons.

### rc26 (shipped, tag v0.1.0-rc26)
- **TUN DNS fix v2 (the real one)**: `route.auto_detect_interface: true`,
  `dns.final: "local"` (8.8.8.8 via direct), explicit
  `port:53 → dns-out` rule. User confirmed TUN now works
  ("tun заработал").
- Map zoom step 0.05 → 0.03; maxScale 6 → 12.
- Beige background lifted from TransformComponent to `.worldmap` parent
  so letterbox bands don't show white.
- Long URLs in Pool: ellipsis truncate + `title=` for full hover.
- 1000-server clustering placeholder: `scale < 1.8` → only country
  pins; `scale >= 1.8` → host pins. **Replaced in rc27, see §4.**
- Edit modal: `prompt()` → in-app `SubscriptionEditModal` with copper
  highlight, Esc/Enter binds.
- Active server visualization: orange diamond (was teardrop) — three
  states now visually distinct: idle paper outline, hover ink-filled,
  active copper-filled.

### rc27 (this commit set — push + tag yourself if not done)

User reported 7 issues against rc26 plus 1 follow-up + 1 idea. The
rc27 agent shipped 4 of them and deferred the rest to you (rc28).

**Done in rc27 (committed, on branch `devin/1777411409-rc27`):**

1. **IP-geolocation backend.** mosaicd at startup spawns
   `resolveMyLocation` goroutine → `http://ip-api.com/json/?fields=...`
   → caches `proto.GeoLocation` on `state.Manager` → folded into every
   `/v1/status` snapshot as `Status.MyLocation`. Three retries with 5s
   backoff, 8s per-request timeout. Failures silently leave field nil.
   Files: `internal/proto/types.go`, `internal/state/state.go`,
   `cmd/mosaicd/main.go`, `ui/src/api/types.ts`.

2. **vous pin uses real location + click → "It's your location" tooltip.**
   `WorldMap` now takes a `myLocation?: GeoLocation` prop. If present,
   projects from real lat/lon; else falls back to lon=0/lat=20°N.
   Vous label is now `pointer-events: auto` and toggles a tooltip
   showing "It's your location · {city}, {country}" + numeric coords.
   Files: `ui/src/components/WorldMap.tsx`, `ui/src/screens/Main.tsx`,
   `ui/src/styles/app.css`.

3. **SubscriptionDetail long-URL fix.** Table wrapped in
   `.sub-detail-scroll` with `overflow-x: auto` + `min-width: 720px`
   so it never explodes the page chrome. Name column gets
   `max-width: 320px` + `word-break: break-all` + `overflow-wrap:
   anywhere` to wrap signed-URL tokens.
   Files: `ui/src/screens/SubscriptionDetail.tsx`,
   `ui/src/styles/pool.css`.

4. **Pin-scale on HTML labels.** rc26 only inverse-scaled SVG diamonds;
   HTML `.worldmap-label` boxes still grew with zoom. Now they get
   `transform: translate(-50%, 12px) scale(${pinScale})` inline,
   `transformOrigin: "center top"`. Stays the same on-screen size at
   all zoom levels.
   Files: `ui/src/components/WorldMap.tsx`.

**Branch state at rc27 handoff:**
- All 4 changes committed to `devin/1777411409-rc27`.
- `go build ./...`, `go vet ./...`, `npm run lint` all clean.
- PR not yet created (rc27 agent ran out of time mid-PR step). If
  `git_pr action=create` already happened by the time you read this,
  reuse that PR. Else: `git_pr action=fetch_template` then `create`
  with base = `devin/1777403083-rc23-feedback`.
- Tag `v0.1.0-rc27` may or may not be pushed. Check
  `git tag --list | grep rc27`. If absent, push it after CI green.

## 4. What's still pending — rc28 docket

Five items the user wants but the rc27 agent did not get to. Listed in
priority order from the user's last messages.

### 4.1. Adaptive clustering with drill-down click (BIG — half day)

User asked for "drill-down click" (continent → country → city → server,
animated zoom to bbox), then immediately followed up:

> "понимаешь, же что это должно работать адаптивно, тоесть если мало
> серверов, то нет смысла кластеризировать, а если много и возможно
> наложение, то надо"

So the spec is **on-screen-pixel-distance clustering**, not a fixed
hierarchy:

- At each zoom level, project every pin's (x,y) to viewport pixels.
- Run greedy nearest-neighbour merge: any two pins whose viewport
  distance < ~30 px collapse into a single "cluster pin".
- Cluster size scales with member count (sqrt-radius).
- A single isolated server (e.g. one in Japan, 50 in USA at zoom 1×)
  stays as a host pin; the 50-server US lump becomes one cluster.
- Click a cluster → animate `TransformWrapper` to the bbox of its
  members (instance method `setTransform(x, y, scale)` or
  `zoomToElement`). After zoom, re-run clustering at the new scale —
  the cluster will dissolve into smaller clusters or single pins
  emergently. No hard-coded "continent" / "country" levels needed.
- Click a single pin → existing connect/popover behaviour.

rc26 has the `scale` state already wired (`onTransform` → `setScale`).
The current `scale >= 1.8 ? hostPins : []` toggle in
`ui/src/components/WorldMap.tsx` is the placeholder to replace.

**Architecture suggestion:**
- New file `ui/src/components/adaptiveCluster.ts`:
  - `clusterAtScale(pins: PinPos[], scale: number, viewportPx: number)
    → ClusteredPin[]` where `ClusteredPin = { x, y, members:
    PinPos[], bbox: {minX,maxX,minY,maxY} }`.
- WorldMap renders cluster pins (count badge) when `members.length > 1`,
  single host pin otherwise.
- Click on cluster → `transformRef.current.zoomToElement` or
  `setTransform` animated, target bbox padded ~10%.

### 4.2. Map full-bleed (low risk, 30 min)

Currently `.worldmap-stage` has `aspect-ratio: 784/459` — at narrow
viewports the world image fits inside that ratio, leaving beige bands
top/bottom that visibly clip when the user pans. User saw this in rc26
and complained.

Fix: remove `aspect-ratio` from `.worldmap-stage`, let it fill the
parent `.map` container. Inner `<img src={worldUrl}>` keeps its own
aspect via `object-fit: contain` so it doesn't stretch. Beige fill
should still cover the full container so panning past the world image
shows the same colour, not white. Test on narrow + wide windows.

### 4.3. Live metrics on Main (10 min — find why poll isn't binding)

User says `class="metrics"` block on the Main screen still requires F5
to update latency/up/down. The `useLiveServers` poll fires, and
`Status` updates do come via SSE — but the metrics div is reading from
some snapshot that doesn't refresh. Likely a `useState` capture or a
component that takes status only via `props` and isn't re-rendering
when parent's status changes. Open `ui/src/screens/Main.tsx`, find the
`metrics` div, trace back where `latency_ms` / `bytes_in` /
`bytes_out` come from, ensure they read from the live `status` prop.

### 4.4. Daemon-offline banner with auto-retry (45 min)

When the daemon dies (crashed, killed, not yet started), the UI should:
1. Detect /v1/status is unreachable.
2. Show a banner: **"Mosaicd unreachable — auto-retrying every 3s ·
   press F5 for recheck now"** (user-confirmed copy, in English).
3. Keep polling every ~3s; recover automatically when daemon comes
   back.
4. F5 (browser refresh / Tauri reload) forces an immediate retry.

Hook into `useStatus` (or wherever the status request lives) — on
network error, set `status.daemonOffline = true`, render banner at
top of `App.tsx`, keep interval running.

### 4.5. Subscription filter chips above the map (30 min)

User idea: "All · i · ii · iii · iv" chips above the world map, click
to filter pins to one subscription. Used the lowercase-roman
convention from Pool to keep names short; full sub name in `title=`
tooltip.

Plumb a `subscriptionFilter: string | null` state into Main.tsx →
WorldMap, filter `servers` before passing.

## 5. Suggested rc28 plan

1. Verify rc27 PR + tag exist; if not, finish the rc27 agent's work
   (push, PR, tag) before adding rc28 work.
2. Implement 4.1 (adaptive clustering) — biggest item. Smoke-test
   clustering & drill-down with a 1000-server fixture before pushing.
3. Implement 4.2 (full-bleed map).
4. Implement 4.3 (live metrics).
5. Implement 4.4 (offline banner).
6. Implement 4.5 (sub filter chips).
7. Push branch `devin/<ts>-rc28`, PR into
   `devin/1777403083-rc23-feedback`, tag `v0.1.0-rc28`, attach .exe.

## 6. Test expectations for rc28 .exe

The user will:

- Re-open a 1000-server subscription, verify on zoom 1× the US lumps
  into one cluster while a lone Japan server stays a single romb.
- Click cluster → map animates to its bbox + cluster decomposes.
- Disconnect daemon (Stop-Process mosaicd) → banner appears within 3s.
- Restart daemon → banner disappears within 3s, no F5 needed.
- Watch Main metrics tick every ~1s during a connected session
  without page refresh.
- Click vous pin (already shipped in rc27) → tooltip "It's your
  location · …" shows.
- Pan map down → no white bands, beige extends edge-to-edge.

## 7. Useful one-shot snippets

```sh
# Confirm rc27 commit + branch state
cd ~/repos/mosaicvpn
git log --oneline -3 devin/1777411409-rc27
git status -sb

# Create rc28 branch from rc27
git checkout -b devin/$(date +%s)-rc28 devin/1777411409-rc27
```

```sh
# Watch CI for a tag push
PAT="${GITHUB_PAT%% *}"
curl -s -H "Authorization: token $PAT" \
  "https://api.github.com/repos/DangerousANEN/mosaicvpn/actions/runs?per_page=5" \
  | python3 -c 'import sys,json;[print(r["id"], r["status"], r["conclusion"], r["head_branch"], r["created_at"]) for r in json.load(sys.stdin)["workflow_runs"]]'
```

```pwsh
# User's clean reset on Windows
Get-Process mosaicd, mosaic-ui, sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force "$env:APPDATA\com.mosaicvpn.ui" -ErrorAction SilentlyContinue
# Then re-install Mosaic_0.1.0_x64-setup.exe
```

## 8. Suggested first message to the user (translate to Russian)

> "Прочитал HANDOFF + HANDOFF_RC28, картина ясна. rc27 закрыл 4 пункта
> (IP-geo для vous, клик-тултип, длинные URL в Servers, scale на
> лейблы). На rc28 у меня твои 5 хвостов: адаптивная кластеризация с
> drill-down кликом, full-bleed карта, live-метрики на Main,
> offline-баннер, фильтр-чипы по подпискам. Беру по порядку, начну с
> кластеризации. CI ~10 мин на каждый тег."

— rc27 agent, signing off.
