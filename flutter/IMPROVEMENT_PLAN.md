# MosaicVPN — Grand Improvement Plan
> v0.2.0 → v1.0.0
> Last updated: 2026-07-20

---

## Current State

### Go Daemon (28 .go files, ~5k LOC)
**API routes (42 endpoints):**
- `GET /v1/status`, `POST /v1/connect`, `POST /v1/disconnect`
- `GET/POST /v1/subscriptions`, `POST /v1/subscriptions/{id}/refresh`, `PATCH/DELETE /v1/subscriptions/{id}`
- `GET /v1/servers`, `POST /v1/servers/{id}/test`, `POST /v1/servers/test-all`
- `GET/POST /v1/rules`, `DELETE /v1/rules/{id}`, `POST /v1/rules:reorder`
- `GET/PUT /v1/prefs`
- `GET/POST /v1/profiles`, `PUT/DELETE /v1/profiles/{id}`, `POST /v1/profiles/{id}/activate`
- `GET/POST /v1/route-profiles`, `PUT/DELETE /v1/route-profiles/{id}`
- `GET /v1/connections`, `POST /v1/connections/{id}/close`, `POST /v1/connections/close-all`
- `GET /v1/stats`, `POST /v1/stats/reset`
- `GET/PUT /v1/dns`
- `POST /v1/test/url`, `POST /v1/test/ip`, `POST /v1/test/speed`
- `GET/PUT /v1/warp`
- `POST /v1/import/clipboard`, `POST /v1/import/link`
- `GET /v1/diag`, `GET /v1/events` (SSE)

**Missing from Go daemon (exists only in Flutter MockDaemonApi):**
- ❌ Egresses (proxy listeners CRUD) — mock only
- ❌ ServerGroups (server grouping) — mock only
- ❌ Cores (sing-box core management) — mock only
- ❌ Anti-DPI / fragmentation settings — mock only
- ❌ Export/import config — mock only
- ❌ Favorites (client-side only, OK)
- ❌ Speed test per server (only global speed test exists)

**Go Store (persistent state):**
- Subscriptions, Servers, Rules, Prefs, Profiles, RouteProfiles, WARP
- NO: Egresses, ServerGroups, DNS config persistence (DNS is in Prefs)

**Go Backend interfaces:**
- `Backend` — Start/Stop/Stats
- `ConnectionBackend` — Connections/Close/CloseAll
- `StatsBackend` — TrafficStats/ResetStats
- `TestBackend` — TestURL/TestIP/SpeedTest
- `ProxyListener` — Proxies (SOCKS/HTTP addresses)

### Flutter App (42 .dart files, ~14.7k LOC)
**Screens connected to sidebar (7):**
1. Dashboard (`dashboard_screen.dart`, ~1050 lines) — map + status + stats + quick connect
2. Stations (`servers_screen.dart`, ~1550 lines) — subscriptions + servers list, context menus, multi-select
3. Routing (`routing_screen.dart`, ~348 lines) — rules list, reorder, add/edit
4. Egresses (`egresses_screen.dart`) — proxy listeners CRUD (⚠️ mock only!)
5. Activity (`connections_screen.dart`) — live connections, close
6. Logs (`logs_screen.dart`) — log viewer
7. Settings (`settings_screen.dart`) — prefs, DNS, WARP, theme, about

**Screens written but NOT in sidebar (5 orphans):**
1. `stats_screen.dart` — traffic charts, speed graph
2. `speed_test_screen.dart` — downloadable/upload speed test UI
3. `profiles_screen.dart` — VPN profiles CRUD
4. `subscriptions_screen.dart` — subscription management (separate from servers)
5. `cores_screen.dart` — sing-box core management (⚠️ mock only!)

**Providers (vpn_providers.dart, ~340 lines):**
- `daemonApiProvider` → MockDaemonApi (hardcoded mock, not real)
- `subscriptionsProvider`, `serversProvider`, `rulesProvider`, `connectionsProvider`
- `statusProvider`, `statsProvider`, `preferencesProvider`, `dnsConfigProvider`
- `profilesProvider`, `routeProfilesProvider`, `warpConfigProvider`
- `egressesProvider`, `serverGroupsProvider`, `favoriteServersProvider`
- `connectStateProvider`, `addSubscriptionTriggerProvider`
- `logStreamProvider` (SSE from daemon)
- Polling: every 2s for status/stats/connections

**Models (8 files):**
- `server.dart` (Server, ServerFields, Subscription, ServerGroup)
- `status.dart` (VpnStatus, TrafficStats, TrafficPoint, Connection, Profile, RouteProfile)
- `preferences.dart` (Preferences, DNSConfig, WARPConfig, Rule, RuleMatch, TestResult, SpeedTestResult, IPInfo, Egress)
- `manual_server_config.dart`
- `protocol.dart`
- `city_coords.dart`

**Shared widgets (3 files, ~700 lines):**
- `atlas_widgets.dart` (AtlasCard, InkPanel, SectionHeader, StatTile, StatusDot, LatencyBadge)
- `world_map_widget.dart` — SVG world map with server pins, zoom/pan, client location
- (no shared dialog helpers, no form widgets, no empty state widget)

**MockDaemonApi (~1255 lines):**
- Full CRUD for all entities
- Simulated latency tests with random delays
- Simulated connect/disconnect with state transitions
- SSE-like status updates via timer
- Seed data: 0 subs, 0 servers (q10 choice), 3 rules, 2 profiles, 3 connections, 3 egresses

**DaemonApi (real, ~400 lines):**
- Uses Dio HTTP client
- Reads lockfile for host/port/token
- Implements same interface as MockDaemonApi
- Has `getEvents()` for SSE stream
- ⚠️ `daemonApiProvider` uses MockDaemonApi, not DaemonApi

---

## Phase 1: Cleanup & Warnings  (30 min)

- [ ] 1.1 Fix all `flutter analyze` warnings in dashboard_screen.dart (unused variables, deprecated APIs)
- [ ] 1.2 Fix warnings in servers_screen.dart
- [ ] 1.3 Fix warnings in world_map_widget.dart
- [ ] 1.4 Fix warnings in mock_daemon_api.dart
- [ ] 1.5 Fix warnings in atlas_widgets.dart
- [ ] 1.6 Run `flutter analyze` on whole project — get to 0 errors, 0 warnings
- [ ] 1.7 Run `dart format .` — consistent formatting
- [ ] 1.8 Audit deprecated API usage (`withOpacity` → `withValues`, `MaterialStateProperty` → `WidgetStateProperty`)

---

## Phase 2: Connect Orphan Screens  (2h)

- [ ] 2.1 Add `stats_screen.dart` to sidebar nav as "Statistics" with bar_chart icon
- [ ] 2.2 Add `speed_test_screen.dart` to sidebar nav as "Speed Test" with speed icon
- [ ] 2.3 Add `profiles_screen.dart` to sidebar nav as "Profiles" with shield icon
- [ ] 2.4 Add `subscriptions_screen.dart` to sidebar nav as "Subscriptions" with cloud_download icon
- [ ] 2.5 Decide on `cores_screen.dart` — either add to sidebar or gate behind "advanced" flag (since Go daemon has no core management endpoint)
- [ ] 2.6 Add keyboard shortcuts: `Ctrl+1..9` to switch between sidebar tabs
- [ ] 2.7 Add tooltips to sidebar items
- [ ] 2.8 Add badge count on sidebar items (e.g., active connections count on Activity)

---

## Phase 3: Map Widget Enhancements  (4h)

- [ ] 3.1 **Animated arc** — draw curved arc between client and connected server (not straight line). Arc should pulse when data flows.
- [ ] 3.2 **Data flow animation** — animated dots traveling along the arc, speed proportional to traffic
- [ ] 3.3 **Mouse wheel zoom** — `Listener` with `onPointerSignal` to zoom in/out with scroll wheel
- [ ] 3.4 **Pan/drag** — drag the map to pan (not just zoom buttons). Constrain to world bounds.
- [ ] 3.5 **Pinch-to-zoom** — `ScaleGestureRecognizer` for trackpad/touch
- [ ] 3.6 **Pin tooltips** — on hover over a server pin, show tooltip with name, country, latency
- [ ] 3.7 **Pin click** — click a pin to select the server (open its info panel/drawer)
- [ ] 3.8 **Double-click** — double-click pin to connect immediately
- [ ] 3.9 **Legend** — small legend overlay: "● Connected  ● Selected  ● Available"
- [ ] 3.10 **Minimap** — small overview map in corner showing full world + viewport rectangle
- [ ] 3.11 **Country labels** — show country names on map at appropriate zoom levels
- [ ] 3.12 **Dark/light map variants** — switch map colors with theme
- [ ] 3.13 **Connection line style** — dashed when connecting, solid when connected, red when error
- [ ] 3.14 **Multiple connections** — if connected to multiple egresses, show multiple arcs
- [ ] 3.15 **Zoom to selection** — `Ctrl+Shift+F` to fit selected server(s) in view

---

## Phase 4: UX / Interaction  (4h)

- [ ] 4.1 **Global search** (`Ctrl+F`) — search across servers, subscriptions, rules, profiles
- [ ] 4.2 **Context menus** — right-click on server/server group for full context menu (connect, test, edit, delete, favorite, copy link)
- [ ] 4.3 **Drag & drop** — drag servers between groups, drag rules to reorder, drag profile to activate
- [ ] 4.4 **Undo/redo** — `Ctrl+Z` / `Ctrl+Shift+Z` for delete operations, with SnackBar "Server deleted [UNDO]"
- [ ] 4.5 **Keyboard shortcut overlay** — `?` or `F1` shows all shortcuts in a dialog
- [ ] 4.6 **Confirm dialogs** — standardized confirm dialog for destructive actions (dalete server, delete rule, disconnect)
- [ ] 4.7 **Empty states** — every screen has a proper empty state with icon, message, and CTA button
- [ ] 4.8 **Loading states** — skeleton loaders (shimmer) instead of plain CircularProgressIndicator
- [ ] 4.9 **Error states** — every AsyncValue.when has a proper error widget with retry button
- [ ] 4.10 **SnackBar standardization** — success (green), error (red), info (blue) with consistent styling
- [ ] 4.11 **Responsive layout** — adapt to narrow windows (single column) and wide windows (multi column)
- [ ] 4.12 **Sort & filter** — servers: sort by name/latency/country/favorites; filter by protocol, country, subscription
- [ ] 4.13 **Column visibility** — in servers list, let user toggle which columns are visible
- [ ] 4.14 **Batch operations** — already have multi-select; add batch: tag, move to group, export
- [ ] 4.15 **Copy server URI** — right-click → "Copy Share Link" (vless://, vmess://, etc.)
- [ ] 4.16 **Drag to tray** — drag window to top to maximize, snap left/right (OS-level, but ensure app handles it)

---

## Phase 5: Real Daemon Integration  (8h)

- [ ] 5.1 **Switch `daemonApiProvider`** — from MockDaemonApi to real DaemonApi, with flag to fall back to mock if daemon not running
- [ ] 5.2 **Lockfile discovery** — find lockfile at `%LOCALAPPDATA%\MosaicVPN\daemon.lock` (Windows) and `~/.local/share/mosaicvpn/daemon.lock` (Linux). Read host, port, token.
- [ ] 5.3 **Daemon health check** — on app start, ping `GET /v1/status`. If unreachable, show "Daemon not running" banner with button to start it.
- [ ] 5.4 **Auto-start daemon** — option in settings to auto-start daemon on app launch (launch `mosaicd.exe` as subprocess)
- [ ] 5.5 **SSE events** — use `GET /v1/events` SSE stream for realtime status/connection updates instead of 2s polling
- [ ] 5.6 **Auth token** — read bearer token from lockfile, attach to all Dio requests
- [ ] 5.7 **Error handling** — standardized error handling for 401 (token expired), 403 (forbidden), 500 (daemon error), connection refused
- [ ] 5.8 **Reconnection** — if daemon restarts, auto-reconnect SSE stream and re-auth
- [ ] 5.9 **Daemon version check** — compare Flutter's expected API version with daemon version. Warn if mismatched.
- [ ] 5.10 **Daemon logs stream** — `GET /v1/diag` for diagnostic info. Add "Download diagnostics" button in settings.
- [ ] 5.11 **Profile activation** — `POST /v1/profiles/{id}/activate` — wire to profiles_screen.dart
- [ ] 5.12 **URL test** — `POST /v1/test/url` — latency test through tunnel
- [ ] 5.13 **IP test** — `POST /v1/test/ip` — show apparent egress IP, country, ISP
- [ ] 5.14 **Speed test** — `POST /v1/test/speed` — real speed test through tunnel
- [ ] 5.15 **Import** — `POST /v1/import/clipboard` and `POST /v1/import/link` — wire to add_server_dialog.dart
- [ ] 5.16 **WARP config** — `GET/PUT /v1/warp` — wire to settings_screen.dart
- [ ] 5.17 **DNS config** — `GET/PUT /v1/dns` — wire to settings_screen.dart
- [ ] 5.18 **Diag report** — `GET /v1/diag` — show in settings > diagnostics

---

## Phase 6: Missing Go Endpoints  (backend, 8h)

These features exist in Flutter MockDaemonApi but have NO Go endpoint:

- [ ] 6.1 **Egresses CRUD** — add Go endpoints: `GET/POST /v1/egresses`, `PUT/DELETE /v1/egresses/{id}`. Add Egress to store.State. Implement proxy listener management in sing-box backend.
- [ ] 6.2 **ServerGroups CRUD** — add Go endpoints: `GET/POST /v1/groups`, `PUT/DELETE /v1/groups/{id}`. Add ServerGroup to store.State.
- [ ] 6.3 **Per-server speed test** — `POST /v1/servers/{id}/speed` — test speed to specific server (not just global)
- [ ] 6.4 **Export config** — `GET /v1/export` — export full config as JSON/YAML
- [ ] 6.5 **Import config** — `POST /v1/import/config` — import config from JSON/YAML file
- [ ] 6.6 **Anti-DPI settings** — add fields to Prefs: `FragmentEnabled`, `FragmentSize`, `TLSFingerprint`. Wire to sing-box transport config.
- [ ] 6.7 **Ping all servers in parallel** — improve `POST /v1/servers/test-all` to use goroutine pool for parallel testing
- [ ] 6.8 **Server rename** — `PATCH /v1/servers/{id}` — allow renaming individual servers
- [ ] 6.9 **Server favorites** — optionally store favorites server-side (or keep client-only via SharedPreferences)
- [ ] 6.10 **Subscription update interval** — `PATCH /v1/subscriptions/{id}` — change URL, name, refresh interval, auto-refresh
- [ ] 6.11 **Logs endpoint** — `GET /v1/logs` — structured log streaming (currently only diag has recent logs)
- [ ] 6.12 **Log level filter** — `GET /v1/logs?level=error` — filter logs by severity

---

## Phase 7: Desktop Integration  (4h)

- [ ] 7.1 **System tray** — tray icon showing connection status (connected/disconnected/connecting). Right-click menu: Connect, Disconnect, Servers (submenu), Quit.
- [ ] 7.2 **Minimize to tray** — option to minimize to tray instead of taskbar
- [ ] 7.3 **Close to tray** — close button minimizes to tray (if enabled in settings)
- [ ] 7.4 **Tray notifications** — system notification on connect/disconnect/error
- [ ] 7.5 **Window single instance** — if app is already running, focus existing window instead of launching new one
- [ ] 7.6 **Auto-start on login** — option in settings to start app with Windows/Linux
- [ ] 7.7 **Daemon autostart** — start daemon as system service / user service on OS boot
- [ ] 7.8 **Window state persistence** — remember window size, position, sidebar collapsed state
- [ ] 7.9 **Dark/light theme** — theme picker (currently hardcoded dark atlas theme). Add light variant.
- [ ] 7.10 **Custom title bar** — optional custom title bar with MosaicVPN branding (or keep native)
- [ ] 7.11 **Global hotkey** — toggle VPN connection with global hotkey (e.g., Ctrl+Shift+M)
- [ ] 7.12 **Clipboard monitor** — detect VPN URIs (vless://, vmess://, etc.) copied to clipboard and offer to import

---

## Phase 8: Stats & Speed Test  (3h)

- [ ] 8.1 **Real stats** — wire stats_screen.dart to `GET /v1/stats` with SSE updates (TrafficStats.Series)
- [ ] 8.2 **Speed graph** — upload/download speed over time as line chart (use TrafficPoint series)
- [ ] 8.3 **Traffic by server** — per-server traffic breakdown (requires Go endpoint or derive from connections)
- [ ] 8.4 **Data usage today/month** — cumulative data usage with reset at midnight/month start
- [ ] 8.5 **Connection count graph** — active connections over time (PeakConnCount)
- [ ] 8.6 **Speed test UI** — wire speed_test_screen.dart to `POST /v1/test/speed`
- [ ] 8.7 **Speed test history** — store last N speed tests, show comparison
- [ ] 8.8 **IP info display** — show apparent IP after connect: `POST /v1/test/ip` — IP, country, city, ISP, ASN
- [ ] 8.9 **Latency test all** — parallel ping animation in UI, show progress
- [ ] 8.10 **Export stats** — export stats as CSV/JSON

---

## Phase 9: Settings & Preferences  (3h)

- [ ] 9.1 **DNS settings** — wire DNSConfig to `GET/PUT /v1/dns`. Modes: fake-ip, real-ip. Proxied DNS (DoH), Direct DNS, FakeIP exclude list, hosts overrides, disable cache, disable fallback
- [ ] 9.2 **WARP settings** — wire WARPConfig to `GET/PUT /v1/warp`. Enable, mode, license key, team token, bind addr
- [ ] 9.3 **Tunnel mode** — TUN vs proxy mode toggle. Explain differences.
- [ ] 9.4 **Kill switch** — toggle. When enabled, block all traffic if VPN disconnects unexpectedly
- [ ] 9.5 **Allow LAN** — allow LAN traffic to bypass tunnel
- [ ] 9.6 **Block IPv6** — disable IPv6 traffic
- [ ] 9.7 **MTU** — configurable MTU size (default 1420)
- [ ] 9.8 **Bypass processes** — list of processes that bypass VPN (e.g., `ping.exe`, `traceroute`)
- [ ] 9.9 **Share over LAN** — share VPN connection over LAN (bind addr, allow list)
- [ ] 9.10 **MCP settings** — enable MCP server, addr, permission level (read/connect/full), confirm flag
- [ ] 9.11 **Auto-start** — service / user / manual
- [ ] 9.12 **Auto-connect** — connect on app/daemon start
- [ ] 9.13 **Show on launch** — show window on daemon start
- [ ] 9.14 **Theme picker** — dark atlas (current), light atlas, high contrast, system
- [ ] 9.15 **Language** — i18n: English, Russian, Chinese
- [ ] 9.16 **Reset preferences** — reset to defaults button
- [ ] 9.17 **Export/Import settings** — export all settings as JSON
- [ ] 9.18 **Diagnostics** — "Generate Report" button → calls `GET /v1/diag`, shows formatted report, "Copy to clipboard" / "Save as file"

---

## Phase 10: Security Hardening  (ongoing)

- [ ] 10.1 **Kill switch implementation** — actual OS-level firewall rules to block traffic on disconnect (Windows: netsh, Linux: iptables/nftables)
- [ ] 10.2 **DNS leak protection** — ensure DNS queries go through tunnel, not leak to system resolver
- [ ] 10.3 **WebRTC leak** — disable WebRTC in browser traffic (can't control from VPN, but can warn user)
- [ ] 10.4 **Certificate verification** — verify server TLS certificates, warn on self-signed
- [ ] 10.5 **Token rotation** — rotate bearer token on reconnection, store securely (Windows Credential Manager, Linux keyring)
- [ ] 10.6 **Lockfile permissions** — ensure lockfile has restrictive permissions (0600)
- [ ] 10.7 **Process isolation** — run daemon as separate user/service, not as current user
- [ ] 10.8 **Auto-disconnect on sleep** — disconnect VPN before system sleep, reconnect on wake
- [ ] 10.9 **Split tunneling** — per-app routing: some apps through VPN, some direct (requires process matching in rules engine)
- [ ] 10.10 **Multi-hop** — chain multiple servers (client → server A → server B → internet)
- [ ] 10.11 **Protocol obfuscation** — fragmentation, mux, TLS fingerprint randomization for anti-DPI

---

## Phase 11: Android  (long-term)

- [ ] 11.1 **VpnService** — Android VPN tunnel using `VpnService.Builder`, wire to sing-box Android backend
- [ ] 11.2 **Adaptive layout** — responsive layout: phone (bottom nav), tablet (sidebar), desktop (sidebar)
- [ ] 11.3 **Quick settings tile** — Android Quick Settings tile to toggle VPN
- [ ] 11.4 **Widget** — home screen widget showing connection status + quick toggle
- [ ] 11.5 **Always-on VPN** — Android "Always-on VPN" + "Block without VPN" support
- [ ] 11.6 **Per-app mode** — Android per-app VPN (include/exclude apps)
- [ ] 11.7 **Foreground service** — daemon runs as foreground service with notification
- [ ] 11.8 **Import from intent** — handle `vless://` and `vmess://` intents
- [ ] 11.9 **Material 3** — Material 3 design for Android (while keeping atlas theme on desktop)
- [ ] 11.10 **CI for Android** — build APK in CI, test on emulator

---

## Phase 12: Architecture & Code Quality  (4h)

- [ ] 12.1 **Riverpod code generation** — switch from manual providers to `@riverpod` annotations with `riverpod_generator`
- [ ] 12.2 **GoRouter** — replace custom navigation with `go_router` for deep linking, better history
- [ ] 12.3 **Freezed models** — use `freezed` + `json_serializable` for immutable models with copyWith, equality, union types
- [ ] 12.4 **Hive/Isar** — local persistence for favorites, window state, cached data (instead of SharedPreferences)
- [ ] 12.5 **Repository pattern** — extract data access into repository classes, separate from providers
- [x] 12.6 **Error types** — define `DaemonError` enum/class hierarchy: `ConnectionRefused`, `AuthFailed`, `NotFound`, `ServerError`, `Timeout` → `ui_constants.dart`
- [x] 12.7 **Config class** — central config: API base URL, lockfile path, app version, supported protocols → `config/app_config.dart`
- [x] 12.8 **Constants** — extract magic numbers (poll interval 2s, max zoom 3.0, pin sizes, colors) into constants file → `config/ui_constants.dart`
- [ ] 12.3 **Simplify screens** — split 1550-line servers_screen.dart into smaller widgets: `ServerListTile`, `SubscriptionGroupTile`, `ServerContextMenu`, `SortFilterBar`
- [ ] 12.10 **Simplify mock** — split 1255-line mock_daemon_api.dart into per-entity mixins
- [x] 12.11 **Shared form widgets** — `AtlasTextField`, `AtlasDropdown`, `AtlasSwitch`, `AtlasSlider` for consistent form styling → `widgets/atlas_form_widgets.dart`
- [x] 12.12 **Shared dialog helpers** — `showConfirmDialog()`, `showInputDialog()`, `showColorPicker()` → `widgets/atlas_dialogs.dart`

---

## Phase 13: Polish & Branding  (3h)

- [ ] 13.1 **App icon** — proper MosaicVPN icon (not Flutter default). Multi-resolution: 16px to 512px.
- [ ] 13.2 **Installer branding** — MSIX installer with publisher name, app description, splash screen
- [ ] 13.3 **About dialog** — app version, daemon version, links: website, GitHub, privacy policy, license
- [ ] 13.4 **Onboarding** — 3-slide onboarding for first launch: "Welcome to MosaicVPN" → "Add your first subscription" → "Connect to a server"
- [ ] 13.5 **Empty state art** — custom atlas-style illustration for empty states (not just icon + text)
- [ ] 13.6 **Loading animation** — atlas-style loading animation (compass spinning, map unfolding)
- [ ] 13.7 **Sound effects** — optional: connection sound on connect/disconnect (toggle in settings)
- [ ] 13.8 **Window icon** — taskbar window icon with connection status indicator
- [ ] 13.9 **Splash screen** — brief splash on launch while daemon connects
- [ ] 13.10 **Animations** — `flutter_animate` or custom: fade/slide transitions between screens, micro-interactions on buttons

---

## Phase 14: Testing & CI  (long-term)

- [ ] 14.1 **Unit tests** — test DaemonApi against mock HTTP server (MockWebServer pattern)
- [ ] 14.2 **Widget tests** — test each screen with mocked providers (ProviderScope overrides)
- [ ] 14.3 **Integration tests** — full flow: add subscription → parse servers → connect → verify status
- [ ] 14.4 **Golden tests** — screenshot tests for atlas theme consistency
- [ ] 14.5 **Go tests** — expand coverage: API handlers, state manager, subscription parsers, rule engine
- [ ] 14.6 **CI pipeline** — GitHub Actions: lint, test, build Windows/Linux/Android artifacts on tag
- [ ] 14.7 **Coverage** — generate lcov coverage reports, upload to Codecov
- [ ] 14.8 **Docker test env** — Dockerfile with sing-box + mosaicd for integration testing

---

## Phase 15: Distribution  (long-term)

- [ ] 15.1 **Windows MSIX** — package as MSIX installer with code signing
- [ ] 15.2 **Windows portable** — ZIP package for portable use
- [ ] 15.3 **Linux AppImage** — AppImage for portable Linux
- [ ] 15.4 **Linux .deb** — Debian/Ubuntu package
- [ ] 15.5 **Linux .rpm** — Fedora/RHEL package
- [ ] 15.6 **Android APK** — signed release APK
- [ ] 15.7 **Android AAB** — Play Store bundle
- [ ] 15.8 **Auto-update** — check for updates on GitHub releases, download and install
- [ ] 15.9 **Release notes** — auto-generated from conventional commits
- [ ] 15.10 **GitHub Releases** — automated release pipeline on git tag

---

## Phase 16: Advanced Features  (future)

- [ ] 16.1 **MCP server** — expose daemon control via MCP (Model Context Protocol) for AI agent integration. Already has `MCPEnabled` in Prefs.
- [ ] 16.2 **Multi-hop chains** — UI for creating and managing multi-hop routes (client → hop1 → hop2 → internet)
- [ ] 16.3 **Load balancing** — distribute traffic across multiple servers automatically
- [ ] 16.4 **Auto-connect rules** — connect to specific server based on SSID/network/profile/time
- [ ] 16.5 **Stealth mode** — full stealth config: TLS fragment + mux + uTLS fingerprint + WS/gRPC transport
- [ ] 16.6 **Custom geosite/geoip** — download and manage custom geosite/geoip databases
- [ ] 16.7 **Rule presets** — community-shared rule presets (like clash rule providers)
- [ ] 16.8 **Server recommendations** — recommend best server based on latency, load, location
- [ ] 16.9 **Connection tester** — test if specific domains/IPs are reachable through tunnel
- [ ] 16.10 **Bandwidth limiter** — limit upload/download bandwidth per profile
- [ ] 16.11 **Traffic accounting** — track data usage per app, per server, per day/month
- [ ] 16.12 **Scheduled connections** — connect/disconnect at specific times (e.g., work hours only)
- [ ] 16.13 **URL rewrite** — rewrite URLs in transit (e.g., redirect http to https)
- [ ] 16.14 **Custom DNS entries** — per-domain DNS overrides (hosts file on steroids)
- [ ] 16.15 **PAC script** — Proxy Auto-Config script generation for browsers
- [ ] 16.16 **Split DNS** — different DNS servers for different domains
- [ ] 16.17 **Protocol simulation** — simulate specific protocols for testing/debugging

---

## Sprint Plan

### Sprint 1 (Quick wins, ~6h)
- Phase 1: Cleanup (30m)
- Phase 2: Connect orphan screens (2h)
- Phase 4.7-4.9: Empty/loading/error states (1h)
- Phase 8.1-8.2: Real stats + speed graph (1h)
- Phase 5.1-5.3: Switch to real DaemonApi with fallback (1.5h)

### Sprint 2 (Core features, ~12h)
- Phase 5: Full real daemon integration (8h)
- Phase 6: Missing Go endpoints — egresses, server groups, per-server speed test (4h)

### Sprint 3 (Polish, ~8h)
- Phase 3: Map enhancements (4h)
- Phase 4: UX improvements (4h)

### Sprint 4 (Desktop, ~4h)
- Phase 7: Desktop integration — tray, autostart, notifications

### Sprint 5 (Settings, ~6h)
- Phase 9: Settings & preferences full wiring

### Sprint 6 (Testing, ~8h)
- Phase 14.1-14.4: Flutter testing

### Sprint 7+ (Long-term)
- Phase 10: Security hardening
- Phase 11: Android
- Phase 15: Distribution
- Phase 16: Advanced features

---

## Metrics

| Metric | Current | Target v1.0 |
|--------|---------|-------------|
| flutter analyze errors | 0 | 0 |
| flutter analyze warnings | ~15 | 0 |
| Test coverage | 0% | 60%+ |
| Screens connected | 7 | 12 |
| Go endpoints | 42 | 52+ |
| Mock-only features | 5 | 0 |
| Real daemon integration | ❌ | ✅ |
| Desktop tray | ❌ | ✅ |
| Auto-update | ❌ | ✅ |
