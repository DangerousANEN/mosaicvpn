# Audit: Latency/Group Testing Implementations — Probe Upgrade Plan
_Generated 2026-09-01 by subagent audit (read-only)_

---

## 1. Current State Summary

### A. Desktop (Go daemon + Flutter/Tauri + React/Tauri)

#### Single-server probe (`POST /v1/servers/{id}/test`)
- **File:** `internal/api/server.go:701–720`, helper `probeServer()`
- **Method:** single plain TCP connect, 5 s timeout → 1 sample
- **Returns:** `TestResult { latency_ms, error }` — no jitter, no loss, no p95, no probe mode field

#### Group-wide probe (`POST /v1/servers/test-group`)
- **File:** `internal/api/server.go:1882–1923`
- **Method:** parallel TCP connect for all servers in a tag group (concurrency=16), 4 s per attempt → 1 sample each
- **Returns:** `[]TestResult` — same flat struct, no multi-metric output

#### Smart Group candidate probe (`POST /v1/groups/{groupID}/probe`)
- **File:** `internal/api/server.go:2020–2083`
- **Method:** 3 sequential TCP connects, 1500 ms each → `CandidateProbeResult`
- **Returns:** `{ samples=3, successes, loss_percent, median_latency_ms, p95_latency_ms, jitter_ms, probe_kind="transport_tcp" }`
- **Hardcoded:** probe_kind is always `"transport_tcp"` — no HTTP GET, no ICMP path
- **Gaps:**
  - No `probe_mode` selector from the client
  - Jitter is computed as `p95 - median` (only 3 samples); RFC 3550 jitter needs ≥5 samples
  - No throughput from this endpoint

#### Speed test (`POST /v1/test/speed`)
- **File:** `internal/state/singbox_backend.go:1730–1820`
- **Method:** HTTPS GET through active sing-box SOCKS, then HTTPS POST upload
- **Policy:** `SpeedProbePolicy` — provider-configurable download URLs, sample bytes (256 KiB–8 MiB), timeout (3–30 s), target_mbps
- **Gaps:**
  - Only runs via the **active** tunnel — cannot probe uninspected candidates
  - No per-server or per-group routing; always routes through active SOCKS

---

### B. Android (Flutter `AndroidHostedDaemonApi`)

#### Single-server probe (`testServer`)
- **File:** `flutter/lib/core/api/android_hosted_daemon_api.dart:263–281`
- **Method:** `_probeTcpLatency()` — single TCP connect, 4 s timeout → **1 sample only**
- **Returns:** `TestResult { latency_ms }` — no jitter, no loss, no p95
- **No** multi-sample loop, no probe_kind field

#### Direct route probe (`testDirectRoute`)  
- **File:** `android_hosted_daemon_api.dart:289–318`
- **Method:** same `_probeTcpLatency`, single sample
- **Gaps:** identical to testServer — 1 sample, TCP only

#### Smart Group candidate probe (`probeGroupCandidate`)
- **File:** `android_hosted_daemon_api.dart:371–394`
- **Method:** `_probeTcpLatency()` — **single** TCP connect (samples=1, hardcoded)
- **Returns:** `SmartGroupProbeResult { successful, samples=1, successes, jitterMs=0, probe_kind="tcp-handshake" }`
- **Critical gaps:**
  - 1 sample → jitter is always 0; loss is binary (0 or 100%)
  - No HTTP GET probe path
  - No multi-sample loop; cannot compute p95

---

### C. Flutter Dart models (shared)

#### `SmartGroupProbeResult`
- **File:** `flutter/lib/core/models/smart_group_quality.dart`
- **Fields present:** `samples, successes, loss_percent, median_latency_ms, p95_latency_ms, jitter_ms, probe_kind, download_mbps, upload_mbps`
- **Quality score formula:** `reliability*0.55 + latency*0.30 + stability*0.15` (ignores speed unless `speedWeight>0`)
- **Status:** model is already rich enough for the upgrade; no field additions needed for ICMP/TCP/HTTP modes

#### `SmartGroupLatencyTest` / `SmartGroupLatencyProgress`
- **File:** `flutter/lib/core/services/smart_group_latency_test.dart`
- **Gap:** No `probe_mode` parameter passed to `probeGroupCandidate`; mode selection must come from `ManifestGroup.clientPolicy`

#### `SmartGroupSelector`
- **File:** `flutter/lib/core/services/smart_group_selector.dart`
- **Gap:** `_score()` reads `policy.speedProbe.targetMbps` but there is no `probe_mode` field on `ManifestClientPolicy`; mode is implicit

---

### D. Go proto types (`internal/proto/types.go`)

#### `CandidateProbeResult`
- **Missing fields:** `probe_kind` is present (string); but no `ProbeMode` enum or `download_mbps`/`upload_mbps` fields
- **Note:** `SmartGroupProbeResult` on the Dart side has `downloadMbps/uploadMbps` but Go's `CandidateProbeResult` does **not** — mismatch

#### `ClientSelectionPolicy`
- **Present:** `Mode` (latency/stability/speed/weighted/fallback), `SpeedProbe SpeedProbePolicy`
- **Missing:** `ProbeMode` field to select ICMP/TCP/HTTP for the latency probe phase (currently only `Mode` affects scoring, not probing)

#### `ManifestGroup`
- **Present:** `ClientPolicy ClientSelectionPolicy`
- **No per-group `ProbeMode`** field; probe type is not yet part of the manifest contract

---

## 2. Gaps vs. Requirements

| Requirement | Android | Desktop Go | Status |
|---|---|---|---|
| ICMP ping | ✗ | ✗ | Not implemented anywhere |
| TCP connect multi-sample (≥5) | ✗ 1 sample | ✓ 3 samples | Insufficient on Android |
| HTTP GET probe | ✗ | ✗ | Not implemented |
| Selectable probe mode | ✗ | ✗ | Hardcoded in both |
| Jitter (true inter-sample) | ✗ (always 0) | Partial (p95−median, only 3 samples) | Inadequate |
| Loss % (multi-sample) | ✗ (binary) | ✓ (3 samples) | Too few on both |
| p95 latency | ✗ | ✓ | Missing on Android |
| Throughput from candidate probe | ✗ | ✗ | Speed is separate endpoint only |
| Per-group probe mode selection | ✗ | ✗ | Not in manifest or policy |
| Best-server selection from results | Partial | Partial | Selector exists, but no mode switch |

---

## 3. Exact Changes Required

### 3.1 Go — `internal/proto/types.go`

**Add `ProbeMode` to `ClientSelectionPolicy`:**
```go
// ProbeMode selects the transport used for latency probes.
// "tcp" (default), "http_get", "icmp" (requires elevated privilege on Linux/macOS).
// The daemon uses "tcp" as fallback when the requested mode is unavailable.
type ProbeMode string

const (
    ProbeModeAuto    ProbeMode = ""          // resolved by daemon to best available
    ProbeModeTCP     ProbeMode = "tcp"
    ProbeModeHTTPGet ProbeMode = "http_get"
    ProbeModeICMP    ProbeMode = "icmp"
)

// Add to ClientSelectionPolicy struct:
ProbeMode    ProbeMode `json:"probe_mode,omitempty"`
ProbeSamples int       `json:"probe_samples,omitempty"` // 3–20; default 5
ProbeURL     string    `json:"probe_url,omitempty"`     // for http_get mode only
```

**Add `DownloadMbps`/`UploadMbps` to `CandidateProbeResult`:**
```go
// CandidateProbeResult — add two fields:
DownloadMbps float64 `json:"download_mbps,omitempty"`
UploadMbps   float64 `json:"upload_mbps,omitempty"`
```

**Update `ClientSelectionPolicy.SetDefaults()`:**
```go
if p.ProbeSamples < 3 {
    p.ProbeSamples = 5
}
if p.ProbeSamples > 20 {
    p.ProbeSamples = 20
}
if p.ProbeMode == "" {
    p.ProbeMode = ProbeModeTCP
}
```

---

### 3.2 Go — `internal/api/server.go` — `handleProbeCandidate`

**Current:** hardcoded 3 TCP samples, `probe_kind="transport_tcp"`
**Required:** read `ProbeMode` from manifest policy; dispatch to appropriate probe; use configurable sample count

```go
// handleProbeCandidate (rewrite body, ~line 2049 onward):
policy := group.ClientPolicy // ManifestGroup already loaded
samples := policy.ProbeSamples
if samples < 3 { samples = 5 }
if samples > 20 { samples = 20 }

mode := policy.ProbeMode
if mode == "" { mode = proto.ProbeModeTCP }

var latencies []int
var probeKind string

switch mode {
case proto.ProbeModeHTTPGet:
    probeKind = "http_get"
    probeURL := policy.ProbeURL
    if probeURL == "" { probeURL = "https://speed.cloudflare.com/__down?bytes=1" }
    // validate HTTPS scheme; fall back to TCP on parse error
    latencies = probeHTTPGet(r.Context(), server.Address, probeURL, samples)
case proto.ProbeModeICMP:
    probeKind = "icmp"
    latencies = probeICMP(r.Context(), server.Address, samples)
    // requires: golang.org/x/net/icmp; needs raw socket privilege or sysctl on Linux
    // fallback to TCP if icmp returns error
default: // tcp
    probeKind = "transport_tcp"
    latencies = probeTCP(r.Context(), server.Address, server.Port, samples)
}

// statistics:
sort.Ints(latencies)
result := computeProbeResult(groupID, req.CandidateID, samples, latencies, probeKind)
writeJSON(w, http.StatusOK, result)
```

**New helper `computeProbeResult`** — computes:
- `median_latency_ms` = `latencies[len/2]`
- `p95_latency_ms` = `latencies[int(0.95*float64(len))]`
- **True jitter** = mean of `|latencies[i+1] - latencies[i]|` (RFC 3550 approximation)
- `loss_percent` = `float64(samples-len(latencies)) * 100 / float64(samples)`

---

### 3.3 Go — `internal/api/server.go` — `handleTestServer` / `handleTestAll` / `handleTestSpeedGroup`

**Current:** single TCP sample only.  
**Required:** increase to 5 TCP samples for single-server test; compute jitter/loss; return extended `TestResult`.

**Add to `proto.TestResult`** (`internal/proto/types.go`):
```go
type TestResult struct {
    ServerID   string    `json:"server_id"`
    ServerName string    `json:"server_name"`
    LatencyMS  int       `json:"latency_ms"`
    P95LatencyMS int     `json:"p95_latency_ms,omitempty"` // NEW
    JitterMS   int       `json:"jitter_ms,omitempty"`       // NEW
    LossPercent float64  `json:"loss_percent,omitempty"`    // NEW
    ProbeKind  string    `json:"probe_kind,omitempty"`      // NEW
    Error      string    `json:"error"`
    TestedAt   time.Time `json:"tested_at"`
}
```

Update `probeServer()` to run 5 samples and populate new fields.  
Update Dart `TestResult.fromJson()` in `flutter/lib/core/models/test_results.dart` to read new fields.

---

### 3.4 Android — `android_hosted_daemon_api.dart` — `_probeTcpLatency` + `probeGroupCandidate`

**Current:** single TCP connect, jitter=0, samples=1.

**Replacement `_probeMultiTcp()`:**
```dart
Future<({int? median, int? p95, int jitter, double lossPercent})>
    _probeMultiTcp(String host, int port, {int samples = 5}) async {
  // resolve host once, then dial N times sequentially
  final latencies = <int>[];
  for (var i = 0; i < samples; i++) {
    final ms = await _probeTcpLatency(host, port);
    if (ms != null) latencies.add(ms);
  }
  if (latencies.isEmpty) {
    return (median: null, p95: null, jitter: 0, lossPercent: 100);
  }
  latencies.sort();
  final median = latencies[latencies.length ~/ 2];
  final p95 = latencies[(latencies.length * 0.95).toInt().clamp(0, latencies.length - 1)];
  // RFC 3550 jitter approximation
  var jitter = 0;
  for (var i = 1; i < latencies.length; i++) {
    jitter += (latencies[i] - latencies[i - 1]).abs();
  }
  jitter = latencies.length > 1 ? jitter ~/ (latencies.length - 1) : 0;
  final lossPercent = (samples - latencies.length) * 100.0 / samples;
  return (median: median, p95: p95, jitter: jitter, lossPercent: lossPercent);
}
```

**Update `probeGroupCandidate`** to call `_probeMultiTcp` and set `samples=5`, `jitterMs=jitter`, `p95LatencyMs=p95`, `lossPercent=lossPercent`.

**Update `testServer`** to call `_probeMultiTcp` with samples=5 and extend returned `TestResult`.

**Add HTTP GET probe path** (`probe_mode == "http_get"` in `ClientPolicy`):
```dart
Future<int?> _probeHttpGetLatency(String url) async {
  // Dart's dart:io HttpClient — measure time-to-first-byte
  final stopwatch = Stopwatch()..start();
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    await resp.drain<void>();
    stopwatch.stop();
    client.close();
    return stopwatch.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}
```

**Add ICMP note:** ICMP is **not available** on Android without root. For Android, `probe_mode=="icmp"` must fall back to TCP with a log warning.

---

### 3.5 Flutter Dart — `smart_group_latency_test.dart`

Add `ProbeMode` awareness: pass `group.clientPolicy.probeMode` through to each call.  
No interface change — `DaemonApiBase.probeGroupCandidate` already passes `groupID` + `candidateID`; the Go daemon reads mode from its own loaded manifest policy (no client-side change to call signature needed for desktop).

For Android the probe mode must be honoured in `AndroidHostedDaemonApi.probeGroupCandidate` (see 3.4).

---

### 3.6 Flutter Dart — `smart_group_quality.dart` — `qualityScore`

**Current:**
```dart
double get qualityScore {
  if (!successful) return -lossPercent;
  final reliability = 1 - (lossPercent.clamp(0, 100) / 100);
  final latency = medianLatencyMs <= 0 ? 0 : 1 / (1 + medianLatencyMs / 150);
  final stability = 1 / (1 + jitterMs / 100);
  return reliability * 0.55 + latency * 0.30 + stability * 0.15;
}
```

**Required** (make weights match `ClientSelectionPolicy` so sorting is consistent):
```dart
double qualityScore({ManifestClientPolicy? policy}) {
  if (!successful) return -lossPercent;
  final lw = policy?.lossWeight ?? 0.55;
  final latw = policy?.latencyWeight ?? 0.30;
  final sw = policy?.stabilityWeight ?? 0.15;
  final spw = policy?.speedWeight ?? 0.0;
  final targetMbps = policy?.speedProbe.targetMbps ?? 50.0;
  final reliability = 1 - (lossPercent.clamp(0, 100) / 100);
  final latency = medianLatencyMs <= 0 ? 0.0 : 1 / (1 + medianLatencyMs / 150);
  final stability = 1 / (1 + jitterMs / 100);
  final measuredMbps = max(downloadMbps, uploadMbps * 0.5);
  final speed = targetMbps > 0 ? (measuredMbps / targetMbps).clamp(0.0, 1.0) : 0.0;
  return reliability * lw + latency * latw + stability * sw + speed * spw;
}
```

---

### 3.7 Flutter Dart — `ManifestClientPolicy` model

**File:** `flutter/lib/core/models/smart_group_quality.dart` — currently `ClientPolicy` is embedded in `ManifestGroup` but **there is no Dart-side model `ManifestClientPolicy`** — its fields are accessed via `group.clientPolicy.*` which comes from the JSON-deserialized `ManifestGroup`.

**Add `ManifestClientPolicy` class** (extract from `ManifestGroup`):
```dart
class ManifestClientPolicy {
  final String mode;       // latency, stability, speed, weighted, fallback
  final String probeMode;  // tcp, http_get, icmp
  final int probeSamples;  // 3–20
  final String probeUrl;   // for http_get
  final int shardSize;
  final int maxParallelProbes;
  final int probeTtlSeconds;
  final int maxFailoverTries;
  final double latencyWeight;
  final double lossWeight;
  final double stabilityWeight;
  final double speedWeight;
  final SpeedProbePolicy speedProbe;
  // ...fromJson, toJson...
}
```

Currently `ManifestGroup.clientPolicy` is typed as an opaque `Map`-ish or inline fields — needs extraction into typed class to pass to `qualityScore`.

---

### 3.8 Groups screen (`flutter/lib/features/groups/groups_screen.dart`) — UI affordance

**Existing:** `_RouteAction.testLatency`, `_RouteAction.testSpeed` are defined but no mode selector is shown.

**Add:** a probe mode selector chip (TCP / HTTP / ICMP) per-group or globally that writes a local preference and is passed to `SmartGroupLatencyTest.run()`. ICMP should be shown as disabled on Android with a tooltip.

---

### 3.9 Speed test screen (`flutter/lib/features/speedtest/speedtest_screen.dart`)

**Gaps:**
- Only tests the **active** connection; no per-server routing
- No multi-sample latency display alongside throughput
- No best-server recommendation from group

**Add:**
- Group selector dropdown (reads `mosaicManifestProvider` groups)
- "Measure per candidate" mode: iterates shard → connect each → speed test → display ranked table
- Display p95, jitter alongside download/upload

---

## 4. Best-Server Selection Integration

`SmartGroupSelector.connect()` already implements quality ranking + failover. The only missing piece for "best stable server selection" is:

1. **Make `measureSpeed=true`** the default when `clientPolicy.speedWeight > 0` (currently optional, called with `measureSpeed: true` in `connect()` but not in `rank()` called by the groups UI)
2. **Surface the winning candidate** in the groups screen after a latency test run (show a "Best" badge on the top-ranked row post-test)
3. **Persist the winning candidate** in a local preference key so auto-reconnect uses it on the next app start — `SmartGroupSelector._writeCache()` already writes probe results; the connect flow uses them via TTL

---

## 5. File Change Index

| File | Change Type | Description |
|---|---|---|
| `internal/proto/types.go` | Add fields | `ProbeMode` type + const, `ProbeSamples`/`ProbeMode`/`ProbeURL` on `ClientSelectionPolicy`; `DownloadMbps`/`UploadMbps` on `CandidateProbeResult`; `P95LatencyMS`/`JitterMS`/`LossPercent`/`ProbeKind` on `TestResult` |
| `internal/api/server.go` | Rewrite body | `handleProbeCandidate` — mode dispatch, configurable samples, true jitter; `handleTestServer`/`handleTestAll` — 5 samples, new fields |
| `internal/state/singbox_backend.go` | No change needed | Speed test already correct; no ICMP needed here |
| `flutter/lib/core/models/smart_group_quality.dart` | Add class | Extract `ManifestClientPolicy`; add `probeMode`, `probeSamples`, `probeUrl` fields; update `qualityScore` signature |
| `flutter/lib/core/models/test_results.dart` | Add fields | `p95LatencyMS`, `jitterMS`, `lossPercent`, `probeKind` on `TestResult` (with `fromJson` reads) |
| `flutter/lib/core/api/daemon_api_base.dart` | No change | Interface already sufficient |
| `flutter/lib/core/api/daemon_api.dart` | No change | HTTP dispatch already correct |
| `flutter/lib/core/api/android_hosted_daemon_api.dart` | Rewrite 3 methods | `_probeTcpLatency` → `_probeMultiTcp` (5 samples); add `_probeHttpGetLatency`; update `probeGroupCandidate`, `testServer`, `testAllServers` |
| `flutter/lib/core/services/smart_group_latency_test.dart` | Minor | Pass probe mode through from `ManifestClientPolicy`; update aggregate to use policy weights |
| `flutter/lib/core/services/smart_group_selector.dart` | Minor | Pass `policy` to `qualityScore` |
| `flutter/lib/features/groups/groups_screen.dart` | Add UI | Probe mode selector chip; "Best" badge on top-ranked result |
| `flutter/lib/features/speedtest/speedtest_screen.dart` | Add UI | Group selector, multi-candidate ranking, p95/jitter display |

---

## 6. ICMP Constraint Notes

| Platform | ICMP availability | Action |
|---|---|---|
| Windows (desktop, mosaicd elevated) | Available via `golang.org/x/net/icmp` with raw sockets when admin | Implement in Go daemon, requires `ProbeMode=="icmp"` |
| Linux (mosaicd) | Available with `CAP_NET_RAW` or `sysctl net.ipv4.ping_group_range` | Implement, document privilege requirement |
| Android (libbox/Flutter) | **Not available** without root (no raw socket permission) | Must fall back to TCP; surface warning in UI |
| iOS (future) | Needs `com.apple.security.network.client` entitlement + privileged socket | Not in current scope |

Go implementation uses `golang.org/x/net/icmp`, already available in the module as a transitive dep (`golang.org/x/net/proxy` is imported in `singbox_backend.go` — confirm `icmp` sub-package is in go.sum before use).

---

## 7. No-Change Items (already complete)

- `CandidateProbeResult` fields `samples`, `successes`, `loss_percent`, `median_latency_ms`, `p95_latency_ms`, `jitter_ms` — **already in Go proto and Dart model**
- `SpeedProbePolicy` — fully implemented in Go and propagated to Dart
- `SmartGroupSelector._score()` composite ranking — correct except policy weights are hardcoded in `SmartGroupProbeResult.qualityScore`
- Speed test through active SOCKS (`POST /v1/test/speed`) — working
- Candidate shard (`GET /v1/groups/{id}/candidates`) — working
- Group probe endpoint (`POST /v1/groups/{id}/probe`) — working but lacks mode/sample upgrade
