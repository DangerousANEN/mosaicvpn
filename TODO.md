# 📋 MosaicVPN Active Task Backlog (TODO)

## 🎯 Current Sprint Goals

### 1. ⚙️ Daemon (`mosaicd`)
- [x] **Weight & Tier Balancing in Pool Engine**
  - Path: `internal/subs/pool.go`
  - Task: Compute `Score = LatencyMS / Weight` and filter nodes according to user tier (`free`, `pro`, `vip`).
- [x] **Offline Manifest Persistence**
  - Path: `internal/store/store.go`, `internal/api/server.go`
  - Task: Save active manifest to disk (`store.json`) via `SaveManifest` and fallback to local cache when VPS is unreachable.
- [x] **Declarative Service Engine**
  - Path: `internal/proto/types.go`, `internal/api/server.go`
  - Task: Process `profile.services[]` definitions (`GET /v1/services/{id}/resolve` for `proxy_picker`, `value_display`, etc.).

---

### 2. 📱 Flutter GUI (`MosaicBox`)
- [x] **Simple / Expert UI Toggle**
  - Path: `flutter/lib/app/app_shell.dart`, `settings_screen.dart`
  - Task: Dynamic navigation destination list based on `advancedMode` preference.
- [x] **Fix Dart Analyzer Warnings**
  - Path: `flutter/lib/features/dashboard/dashboard_screen.dart`
  - Task: Cleaned up async gap BuildContext warnings.
- [x] **Provider Profiles Screen**
  - Path: `flutter/lib/features/provider_profile/provider_profile_screen.dart`
  - Task: Render custom provider cards (MTProto proxy picker, status widgets, support links).

---

### 3. 🌐 Web & Telegram Infrastructure
- [x] **Provider Manifest Update**
  - Path: VPS `/opt/remnawave/manifest/provider_manifest.json`
  - Task: Updated provider manifest with declarative `profile.services[]` (`mtproto-proxy`, `speed_test`, `support`) and `profile.widgets[]`.
- [x] **Telegram Bot Integration**
  - Path: VPS `/opt/mosaic-bot/`
  - Task: Verified deep links and topup endpoints integration.

---

### 4. 📦 Deployment & Verification
- [x] **Daemon & Flutter Windows Release Build**
  - Task: `mosaicd.exe`, `mosaic.exe`, and Flutter `mosaic_vpn.exe` built successfully.
- [x] **E2E Integration Verification**
  - Task: Daemon live testing verified `GET /v1/manifest` and `GET /v1/services/mtproto-proxy/resolve`.
