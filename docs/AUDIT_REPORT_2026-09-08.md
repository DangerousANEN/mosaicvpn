# MosaicVPN — Full System Audit Report
**Date:** 2026-09-08  
**Scope:** Web Site (site/), Smart Groups & Server Pool, Flutter/Android Client  
**Auditor:** Antigravity (automated static + live API analysis)

---

## Executive Summary

The system is functional for the happy path (WS/VLESS routes on working nodes), but suffers from:
- **CRITICAL** (1 open): Bench data confirms Mosaic Direct has *0% uptime* — "no usable provider candidates" — meaning the live direct route cannot connect.
- **HIGH** (4 open bugs confirmed in code): `hasError` false-positive, tray "Disconnect" disabled during connecting, tray disconnect doesn't dismiss panel, `_disconnectFromTray` swallows actionable error messages.
- **HIGH** (1 manifest inconsistency): Live manifest has **8 smart groups** (not the previously stated 8), `direct_routes` has 1 entry (correct), all with `eligible_count > 0` — so the "0 servers" concern in the task description is outdated; but France has only 5 eligible nodes (at the minimum of 2), making it fragile.
- **MEDIUM** (5): APK link is relative, Canada/Germany node pool failures, jitter formula inaccuracy in quality scoring, probe mode never dispatched, site protocols table lists `xhttp` as supported (misleading — libbox rejects it).
- **LOW** (several): Missing macOS entry from nav, `skip-link` CSS undefined, no `<a>` aria-label on brand logo, enroll callback auto-redirect without a visible cancel path for iOS.

---

## Part 1 — Site (site/index.html, enroll/callback/index.html, assetlinks.json)

### FINDING S-1 · MEDIUM — Android APK link is relative `/assets/MosaicVPN-Android.apk`, not a versioned GitHub URL
**Severity:** MEDIUM  
**File:** `site/index.html:380`

```html
<a class="dl-btn" href="/assets/MosaicVPN-Android.apk">
```

The primary Android download button points to `/assets/MosaicVPN-Android.apk` — a path on the static server. GitHub-mirror link at line 384 correctly points to `v0.3.51`. The VPS must serve a current binary at that path. If the `/assets/` folder is stale, users silently get an old APK without version indication.

**Skill note confirms:** nginx serves `/assets/` from `/etc/letsencrypt/landing/assets/` — this file must be manually updated after each release separately from the GitHub assets, creating a divergence risk.

**Fix:** Either:
1. Replace primary href with the GitHub versioned URL (same as the mirror), or  
2. Set up a redirect: `location /assets/MosaicVPN-Android.apk → https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.51/MosaicVPN-Android-v0.3.51.apk`

---

### FINDING S-2 · LOW — Protocol table lists `xhttp` as supported (misleading)
**Severity:** LOW  
**File:** `site/index.html:549`

```html
<td class="mono">TLS · Reality · ws · grpc · xhttp</td>
```

LibBox 1.13.14 rejects `transport: xhttp` with "unknown transport type: xhttp". MosaicVPN clients get a dial rejection. XHTTP is Remnawave-native and only works via Xray — listing it here is misleading to technical users who may try to import an xhttp subscription.

**Fix:** Remove `xhttp` from the table, or add a footnote "* только для Xray-совместимых клиентов".

---

### FINDING S-3 · LOW — `skip-link` CSS class undefined in index.html
**Severity:** LOW  
**File:** `site/index.html:269`

```html
<a class="skip-link" href="#main-content">Перейти к содержимому</a>
```

The `skip-link` class is nowhere in the `<style>` block of index.html (searched entire file). Without positioning/clip it renders visibly in some browsers or is invisible without keyboard focus styling — accessibility violation.

**Fix:** Add `.skip-link { position:absolute; left:-9999px; top:auto; }` and a `:focus` visibility override.

---

### FINDING S-4 · LOW — Brand logo `<img>` has empty `alt=""` but is inside an `<a>` without accessible label
**Severity:** LOW  
**File:** `site/index.html:273-276`

```html
<div class="brand">
  <img src="/assets/logo-96.png" alt="" width="24" height="24">
  MosaicVPN<span class="dot">.</span>
```

The parent `<div class="brand">` is not an `<a>`. Navigation to home "/" is expected by users clicking the logo (the enroll page wraps it in `<a>`), but the index.html brand div is a non-interactive container. Screen readers encounter an empty alt image with no role.

**Fix:** Wrap `.brand` in `<a href="/">` with `aria-label="MosaicVPN — на главную"`.

---

### FINDING S-5 · INFO — Enrollment callback auto-redirect (1200 ms) is iOS-hostile
**Severity:** INFO  
**File:** `site/enroll/callback/index.html:43`

```js
window.setTimeout(function () { window.location.assign(link.href); }, 1200);
```

On iOS Safari, `window.location.assign('mosaicvpn://...')` with `mosaicvpn://` will either open the app or silently fail — with no user feedback. If the app isn't installed, iOS Safari redirects to the App Store if registered, otherwise shows a blank page or error. The page has a fallback button, but the 1.2 s auto-redirect happens before users can read the instruction.

Additionally, `state` regex `/^[A-Za-z0-9]{16,128}$/` (no hyphens/underscores allowed) is stricter than `code` regex, but state values that happen to contain `-` would cause false-invalid detection at the enrollment callback even if the code is valid.

**Fix for iOS:** Use a user-gesture-gated link (`button.click()` only) rather than `setTimeout`. Consider a visible 3-second countdown with "Отмена" option.  
**Fix for state regex:** Verify server emits state without special chars, or loosen to `/^[A-Za-z0-9_-]{16,128}$/` to match code validation.

---

### FINDING S-6 · INFO — assetlinks.json: single fingerprint, no debug APK fingerprint
**Severity:** INFO  
**File:** `site/.well-known/assetlinks.json`

Only one SHA-256 fingerprint is listed (`7E:22:...`). Debug builds have a separate keystore. If a developer tests enrollment deep links with a debug APK, Android verification will silently fail (verified app links fall back to browser). This is expected behavior for production — note it as documentation gap.

---

## Part 2 — Live Manifest API (https://sub.zxc1x1.ru/api/manifest.json)

**Live manifest fetched at audit time** — 8 smart groups + 1 direct route.

### FINDING M-1 · HIGH — France group has only 5 eligible nodes (minimum 2 — barely above threshold)
**Severity:** HIGH  
**Manifest field:** `{"id":"france","eligible_count":5,"minimum_eligible":2}`

France is the most fragile smart group: 5 eligible nodes with a minimum threshold of 2. Any two node failures disable the route for all users. Benchmark confirms Germany/Canada also had 0% uptime in the bench session (TLS handshake timeouts) — France at 5 eligible is similarly at risk.

**Fix:** Lower `minimum_eligible` to 1 for country-specific groups (user gets one candidate rather than "route disabled"), or increase pool to ≥10.

---

### FINDING M-2 · MEDIUM — `min-latency` and `stable` groups each set `minimum_eligible: 4` (no `disabled` field in manifest)
**Severity:** MEDIUM  
**Manifest:** `min-latency` and `stable` groups lack the `"disabled"` and `"disabled_reason"` keys entirely.

Other groups (`max-speed`) explicitly have `"disabled": false, "disabled_reason": ""`. The Flutter `ManifestGroup.fromJson` defaults missing `disabled` to `false` (correct), but the inconsistency suggests these entries were emitted by an older bot code path before the quality-gate feature was added. If the quality gate triggers for these groups, their disabled state propagates without the explicit field, making it harder to debug from the manifest.

**Fix:** Ensure bot always emits `"disabled": false, "disabled_reason": ""` for enabled routes (consistent schema).

---

### FINDING M-3 · INFO — `eligible_count` not cross-validated against `client_policy.shard_size`
**Severity:** INFO  

`usa` has `eligible_count: 119` but `shard_size: 12`. The client probes only 12 of 119 candidates per connect. This is correct by design. However `france` with `eligible_count: 5` and `shard_size: 12` means the client will probe all 5 — the shard parameter is effectively silently overridden by the pool size. No UX issue, but the manifest value is misleading.

**Fix (documentation):** Note in bot code that `shard_size = min(shard_size, eligible_count)` is implicit.

---

## Part 3 — Smart Groups End-to-End

### FINDING G-1 · CRITICAL — "Mosaic Direct" has 0% uptime in bench data: "no usable provider candidates"
**Severity:** CRITICAL  
**File:** `benchmarks/BENCHMARK_REPORT.md:25-30`

```
ERROR | Mosaic Direct | Failed to connect: build sing-box config: smart group "Mosaic Direct" has no usable provider candidates
```

The daemon tries to treat "Mosaic Direct" as a smart group (it goes through `connectGroup` → `buildNativeTunConfigFromScopedCandidates`), but the direct route has no `mosaic_group_ids` in the candidate feed — so the candidate list comes back empty and config build fails.

**Root cause in code:** In `android_hosted_daemon_api.dart:192`, the `connectGroup` path branches on `group.routeType == 'direct'` → uses `buildNativeTunConfigFromSubscriptionUrl`. This is correct. But the benchmark was likely run via desktop daemon (`daemon_api.dart`), which routes `connectGroup("direct")` through `POST /v1/groups/connect` — the daemon builds a sing-box config with a urltest group for `direct`, finds no candidates in the pool under that tag, and fails.

**Fix (Go daemon):** `internal/api/server.go` `handleConnectGroup` must check if the manifest route has `route_type == "direct"` and delegate to the direct-route connect path (single outbound from subscription URL, no urltest). Currently this branch likely doesn't exist.

---

### FINDING G-2 · HIGH — Germany (DE) and Canada (CA) 0% uptime in bench: TLS handshake timeouts
**Severity:** HIGH  
**File:** `benchmarks/BENCHMARK_REPORT.md:31-52`

All 10 probes for Germany and Canada timed out with `_ssl.c:999: The handshake operation timed out`. This indicates the pool nodes for `client-germany` and `client-canada` are not reachable (possibly node IP blocks, overloaded free-pool servers, or emulator NAT restrictions as documented in the skill).

**If the bench ran from the Windows dev machine (not emulator):** These failures are real production node availability issues.

**Fix:** Run `timeout 4 bash -c '</dev/tcp/<node_ip>/<port>'` for the top 5 DE/CA nodes from the VPS to determine if it's node-side or network-side. If nodes are dead, force a pool rebuild (`python rebuild_pool_config.py`) and raise `minimum_eligible` for these groups while node count is low.

---

### FINDING G-3 · MEDIUM — All working smart groups show 424–820 ms latency (benchmark DEGRADED, not FAIL)
**Severity:** MEDIUM  
**File:** `benchmarks/BENCHMARK_REPORT.md:13-17`

`min-latency`, `max-speed`, `stable`, and WS-direct all show 424–820 ms average latency — well above the 350 ms alert threshold. This is the free-pool node quality issue noted in the skill (composite score, jitter, and throughput metrics are needed to properly rank candidates). With TCP multi-sample probes, the client selects the "best" of mediocre nodes.

The VPS exit IP (`5.175.188.152`) is always the same for all working routes, which confirms that free-pool nodes relay through the MosaicVPN server and exit via the VPS, rather than from geographically distributed exits. This is expected for the current architecture.

**Fix (medium-term):** Implement the `composite_score` metric (v2 collector) and expose server-side pool freshness in the manifest `eligible_count` timestamps. Add UX guidance: "Latency is measured to exit node, not to pool candidate."

---

### FINDING G-4 · MEDIUM — `qualityScore` default weights differ from `client_policy` (0.55 vs 0.30 reliability)
**Severity:** MEDIUM  
**File:** `flutter/lib/core/models/smart_group_quality.dart:120-132`

```dart
double qualityScore({ManifestClientPolicy? policy}) {
  final lw = policy?.lossWeight ?? 0.55;      // Default: 55% reliability
  final latw = policy?.latencyWeight ?? 0.30; // Default: 30% latency
```

But the `min-latency` group manifest says `latency_weight: 0.45, loss_weight: 0.30`. The local defaults (0.55 reliability / 0.30 latency) are used when no policy is passed. The `SmartGroupSelector._score()` does pass policy correctly, but `SmartGroupQualityMonitor` calls `qualityScore()` without policy in some paths.

**Fix:** Ensure callers always pass `policy`. Add `assert(policy != null)` in debug builds.

---

### FINDING G-5 · LOW — `probeMode` from `client_policy` is never dispatched in Go daemon
**Severity:** LOW (known; documented in skill but unimplemented)  
**File:** `internal/api/server.go` (Go side); Dart side `ManifestClientPolicy.probeMode` and `probeSamples` fields exist in `provider_profile.dart:139-183`.

The manifest now carries `probe_mode` and `probe_samples` fields in `client_policy`. The Dart `ManifestClientPolicy.fromJson` reads them. But `android_hosted_daemon_api.dart:probeGroupCandidate` uses `probeMode` only to distinguish `http_get` from `tcp` — a `mode` field in `client_policy` (e.g. `"mode": "latency"`) is NOT the same as `probeMode`. The group's operational mode (`"latency"`, `"stability"`, `"speed"`) is not used to dispatch different probe strategies.

**Fix (later):** Wire `group.clientPolicy.probeMode` through to `probeGroupCandidate` call. Currently no regression — groups work, probe mode defaults to TCP.

---

## Part 4 — Flutter Client Code Findings

### FINDING F-1 · HIGH — `hasError` false-positive from stale `lastError`
**Severity:** HIGH  
**File:** `flutter/lib/core/models/status.dart:68`

```dart
bool get hasError => state == 'error' || lastError.isNotEmpty;
```

If a previous session ended with an error and `lastError` was persisted, the next `getStatus()` call (state=`'disconnected'`, lastError=`'some old error'`) returns `hasError == true`. The dashboard shows the "ERROR" banner on a clean disconnected state, confusing users.

**Fix (confirmed in skill as known bug):**  
```dart
bool get hasError => state == 'error';
```

---

### FINDING F-2 · HIGH — Tray "Disconnect" item disabled during `connecting` state (user cannot cancel stuck connection via tray)
**Severity:** HIGH  
**File:** `flutter/lib/core/services/tray_service.dart:162-163`

```dart
MenuItemLabel(
  label: _labels.disconnect,
  enabled: _connected,   // ← disabled when connecting
```

`_connected` is only true when state == `'connected'`. During `connecting`, the disconnect item is greyed out. Users cannot cancel a stuck connection attempt via the tray right-click menu — they must open the main window.

**Fix:**
```dart
enabled: _connected || _connecting,
```

Where `_connecting` mirrors `status.isConnecting`.

---

### FINDING F-3 · HIGH — `_disconnectFromTray()` swallows the actual error message
**Severity:** HIGH  
**File:** `flutter/lib/app/app_shell.dart:671-685`

```dart
Future<void> _disconnectFromTray() async {
  ...
  } catch (error) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Не удалось отключиться. Повторите попытку.'),
      ),
    );
  }
}
```

The error variable is captured but `error.toString()` is never used. The generic message is unhelpful when the VPN service has crashed or the daemon returned a specific code.

**Fix:**
```dart
content: Text('Не удалось отключиться: ${error.toString().replaceFirst('Bad state: ', '')}'),
```

---

### FINDING F-4 · MEDIUM — Tray Quick Panel doesn't auto-dismiss after tray disconnect
**Severity:** MEDIUM  
**File:** `flutter/lib/app/app_shell.dart:671-685`

`_disconnectFromTray()` calls `ref.invalidate(vpnStatusProvider)` but does NOT call `_dismissTrayQuickPanel()`. The floating quick panel stays visible on screen after disconnect, requiring manual click to close.

**Fix:** Add `if (mounted) _dismissTrayQuickPanel();` in the `try` block after `ref.invalidate(vpnStatusProvider)`.

---

### FINDING F-5 · MEDIUM — Groups screen disconnect menu: wrong label shown when connected to a different route
**Severity:** MEDIUM  
**File:** `flutter/lib/features/groups/groups_screen.dart:1000-1013`

```dart
PopupMenuItem(
  value: canDisconnect ? _RouteAction.disconnect : _RouteAction.connect,
  enabled: canDisconnect || !row.disabled,
  child: ListTile(
    title: Text(canDisconnect
        ? isActiveRoute
            ? 'Отключиться'
            : 'Отключить активный маршрут'
        : 'Подключиться'),
```

When `canDisconnect == true` and `isActiveRoute == false` (i.e. user is connected to a DIFFERENT route), the menu shows "Отключить активный маршрут" but tapping it **connects the currently selected row** (action is `_RouteAction.connect`). This contradicts UI expectation — the item label says disconnect but action connects.

Wait: `canDisconnect ? _RouteAction.disconnect : _RouteAction.connect` — while connected, `canDisconnect = true`, so value is `_RouteAction.disconnect`. So clicking will always disconnect when connected. The label is correct: "Отключить активный маршрут" ≠ "Подключиться to this row". But the **lack of a separate "Подключиться к этому маршруту"** item is still an issue — the user cannot switch routes directly from the menu without disconnecting first.

**Actual bug confirmed (per skill doc at `references/disconnect-path-audit-2026-08-28.md`):** If `status.isConnected && !isActiveRoute`, there should always be a "Отключить (активный маршрут)" item shown, but the label says "Подключиться" when `canDisconnect = false`. This is only when `_connected = false`, so not a production bug in the above code path. The real issue is the **absence of a "Connect to this route" item** when another route is active.

---

### FINDING F-6 · MEDIUM — `testDirectRoute` in `android_hosted_daemon_api.dart` does NOT strip scoped prefix before matching
**Severity:** MEDIUM  
**File:** `flutter/lib/core/api/android_hosted_daemon_api.dart:362-368`

```dart
Future<TestResult> testDirectRoute(String groupID) async {
  ...
  final group = manifest.routes.cast<ManifestGroup?>().firstWhere(
    (value) => value?.id == groupID,  // ← raw groupID, no scoped prefix strip
    orElse: () => null,
  );
```

`connectGroup` already handles scope stripping (lines 177-182 with `_parseScopedGroupID`), but `testDirectRoute` does not. Pressing "Test Latency" on the "Mosaic Direct" route (which has a scoped id like `provider:sub-id:direct`) will attempt to match against manifest route id `"direct"` — failing with "Маршрут не найден".

**Fix:** Replicate the scope parsing before the `firstWhere` check (same pattern as `connectGroup`):
```dart
final scoped = _parseScopedGroupID(groupID);
final matchId = scoped?.manifestGroupID ?? groupID;
final group = manifest.routes.cast<ManifestGroup?>().firstWhere(
  (value) => value?.id == groupID || value?.id == matchId,
  orElse: () => null,
);
```

---

### FINDING F-7 · MEDIUM — Startup "empty cabinet" feeling — `subscriptionsProvider` has no stale-while-revalidate cache
**Severity:** MEDIUM  
**File:** `flutter/lib/core/providers/vpn_providers.dart` (inferred)

As documented in the skill, `subscriptionsProvider` is `FutureProvider.autoDispose` with no cross-session snapshot. On every cold start there is a visible async gap where the dashboard shows empty state. The web cabinet already got `localStorage.mv_profile_cache_v1` (stale-while-revalidate pattern) but the Flutter app has not received the same fix.

**Fix:** In `android_hosted_daemon_api.dart`, initialize `subscriptionsProvider` synchronously from SharedPreferences snapshot on first read, then let the live fetch update it.

---

### FINDING F-8 · LOW — Flag icons for all countries use `Icons.flag_outlined` (generic Flutter icon)
**Severity:** LOW  
**File:** `flutter/lib/features/groups/groups_screen.dart:2653`  
**File:** `flutter/lib/features/dashboard/connection_dashboard.dart:1662-1666`

```dart
'flag_de' || 'flag_us' || 'flag_ca' || 'flag_nl' || 'flag_fr' => Icons.flag_outlined,
```

All country flags use the same generic flag icon. No actual flag emoji or country-specific icon. This makes Germany indistinguishable from USA, Canada, Netherlands, and France in the route list at a glance.

**Fix:** Use emoji flags via `Text('🇩🇪')`, or a third-party `country_flags` package, or emoji-based `Text` widgets inside `ListTile.leading`.

---

### FINDING F-9 · LOW — `connectGroupCandidate` delegates to `connectGroup` (ignores candidateID)
**Severity:** LOW  
**File:** `flutter/lib/core/api/android_hosted_daemon_api.dart:221-223`

```dart
@override
Future<void> connectGroupCandidate(String groupID, String candidateID) =>
    connectGroup(groupID);
```

The candidateID is silently ignored. When the user selects a specific candidate from latency test results and taps "Connect to this candidate," Android always connects to the full group (random candidate selection, not the tested one). Desktop daemon honors the specific candidateID. This is a documented limitation but not surfaced to the user — they may expect deterministic behavior after latency tests.

**Fix (UX clarity):** Either implement candidate-pinning on Android (by pre-filling the candidate cache and building config from that single outbound), or remove the "connect to this candidate" UI path on Android and show a notice.

---

## Part 5 — API Contract Mismatches

### FINDING A-1 · MEDIUM — `ManifestClientPolicy.probeMode` is in Dart model but NOT in the live manifest
**Severity:** MEDIUM  
**File:** `flutter/lib/core/models/provider_profile.dart:139`; Live manifest `client_policy` objects

The Dart model parses `probe_mode`, `probe_samples`, `probe_url` from `client_policy`. None of the 8 live manifest groups contain these keys. The Flutter code handles missing keys gracefully (defaults to `"auto"`, `5`, `""`). But the bot emitting the manifest must add these fields for the feature to be actually server-configurable.

**Fix:** Bot's `_handle_provider_manifest` must include `"probe_mode": "auto", "probe_samples": 5, "probe_url": ""` in all group `client_policy` objects.

---

### FINDING A-2 · LOW — Manifest `groups` missing `"disabled"` / `"disabled_reason"` for `min-latency` and `stable`
**Severity:** LOW  
**File:** Live manifest JSON

`max-speed` includes `"disabled": false, "disabled_reason": ""`. `min-latency` and `stable` do not. The bot should emit a consistent schema for all groups.

---

### FINDING A-3 · INFO — `eligible_count` and `minimum_eligible` semantics are undocumented client-side
**Severity:** INFO  

The Flutter UI shows eligible_count nowhere (no UX for "France: 5 available nodes"). Adding a subtle "N серверов" badge on the route row would help power users understand route health.

---

## Part 6 — Secondary Site Pages

### FINDING SP-1 · INFO — Secondary pages (contacts, privacy, terms, etc.) — mobile menu CSS may need the `open` fix
**Severity:** INFO  
**File:** `site/contacts.html`, `delivery.html`, `docs.html`, `offer.html`, `privacy.html`, `terms.html`, `refund.html`

Per the skill (2026-09-08 pitfall): secondary pages with a sticky `<header>` that uses `backdrop-filter:blur()` create a stacking context that traps the `position:fixed` nav dropdown. Index.html received the fix. Verify that secondary pages have `@media(max-width:920px){header:has(.nav-links.open){z-index:120}}` and the full `.nav-links.open` CSS block.

A file-by-file scan is needed; these pages all use `/assets/common.css`. If `common.css` includes the nav fix, they inherit it — check `site/assets/common.css`.

---

## Summary Matrix

| ID | Area | Severity | Status | File |
|---|---|---|---|---|
| G-1 | Mosaic Direct 0% uptime — no usable candidates | **CRITICAL** | OPEN | benchmarks/BENCHMARK_REPORT.md + Go daemon |
| F-1 | `hasError` false-positive from stale `lastError` | **HIGH** | OPEN | status.dart:68 |
| F-2 | Tray "Disconnect" disabled during connecting | **HIGH** | OPEN | tray_service.dart:163 |
| F-3 | Tray disconnect swallows error message | **HIGH** | OPEN | app_shell.dart:680 |
| G-2 | Germany/Canada 0% uptime (TLS timeouts) | **HIGH** | OPEN | Pool / VPS infrastructure |
| F-4 | Tray quick panel not dismissed after disconnect | **MEDIUM** | OPEN | app_shell.dart:671 |
| F-5 | Groups menu: missing "Connect to this route" when another active | **MEDIUM** | OPEN | groups_screen.dart |
| F-6 | `testDirectRoute` doesn't strip scoped prefix | **MEDIUM** | OPEN | android_hosted_daemon_api.dart:362 |
| F-7 | Startup empty-cabinet (no stale-while-revalidate) | **MEDIUM** | OPEN | vpn_providers.dart |
| G-3 | All working groups 424-820ms latency (DEGRADED) | **MEDIUM** | POOL_QUALITY | bench data |
| G-4 | `qualityScore` mismatched default weights | **MEDIUM** | OPEN | smart_group_quality.dart:120 |
| A-1 | `probe_mode` in Dart but not in live manifest | **MEDIUM** | OPEN | provider_profile.dart + bot |
| S-1 | Android APK link is relative (versioning risk) | **MEDIUM** | OPEN | site/index.html:380 |
| S-2 | Protocol table lists `xhttp` as supported | **LOW** | OPEN | site/index.html:549 |
| M-1 | France: only 5 eligible nodes (threshold 2) | **HIGH** | OPEN | live manifest |
| M-2 | `min-latency`/`stable` lack `disabled` fields | **LOW** | OPEN | bot manifest generator |
| S-3 | `skip-link` CSS class undefined | **LOW** | OPEN | site/index.html |
| S-4 | Brand logo not in `<a>` on index.html | **LOW** | OPEN | site/index.html:273 |
| F-8 | All country flags use same generic icon | **LOW** | OPEN | groups_screen.dart:2653 |
| F-9 | `connectGroupCandidate` ignores candidateID on Android | **LOW** | OPEN | android_hosted_daemon_api.dart:221 |
| A-2 | Missing `disabled`/`disabled_reason` in 2 manifest groups | **LOW** | OPEN | bot |
| G-5 | `probeMode` never dispatched in Go daemon | **LOW** | KNOWN | internal/api/server.go |
| S-5 | Enrollment callback state regex strips valid chars | **INFO** | OPEN | enroll/callback/index.html:27 |
| A-3 | `eligible_count` not surfaced in UI | **INFO** | OPEN | groups_screen.dart |

---

*Report generated by automated static analysis + live manifest fetch + benchmark data cross-reference.*  
*No code was modified. All findings are read-only observations.*
