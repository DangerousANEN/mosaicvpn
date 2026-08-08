# 🗺️ MosaicVPN & MosaicBox — Comprehensive Project Status & Architecture Map

> **Note for AI Agents & Developers**: This file is the single source of truth for the **MosaicVPN** ecosystem. It details current system architecture, absolute file locations, API specifications, infrastructure topology, completed features, and the active task TODO list.

---

## 📌 Quick Summary & Product Vision

**MosaicVPN** is a modern, hybrid VPN ecosystem consisting of:
1. **MosaicBox Client App (Flutter desktop & Go daemon `mosaicd`)**: Universal VPN client supporting standard VLESS/Trojan subscriptions AND dynamic MosaicVPN Provider Manifest Pools (Direct Egress, no central relay).
2. **MosaicVPN Service Infrastructure**: Remote backend deployed on VPS (`anenvps`) serving dynamic node pools, web landing SPA (`https://sub.zxc1x1.ru`), and a Telegram bot for subscription management.

---

## 📍 Master File & Infrastructure Reference Map

### Local Workstation (Windows `C:\Users\ANEN\mosaicvpn\`)

#### Go Daemon (`mosaicd`) & CLI (`mosaic`)
- **Daemon Entrypoint**: `cmd/mosaicd/main.go`
- **CLI Entrypoint**: `cmd/mosaic/main.go`
- **Pool Engine & Node Selection**: `internal/subs/pool.go` (URLTest, Fallback, Weighted Round-Robin)
- **Manifest Fetcher & Parser**: `internal/subs/manifest.go`
- **REST API Server**: `internal/api/server.go` (Listens on `http://127.0.0.1:1349`)
- **Data Structs & Protocol**: `internal/proto/types.go`
- **SQLite Database & Key Store**: `internal/store/store.go`
- **Billing & Payments**: `internal/billing/yookassa.go`, `internal/billing/promo.go`, `internal/api/auto_renew.go`
- **WFP Kill Switch Engine**: `internal/killswitch/`
- **Build Output**: `build/mosaicd.exe` (~12 MB), `build/mosaic.exe` (~9.8 MB)

#### Flutter GUI (`MosaicBox`)
- **App Root**: `flutter/`
- **App Shell & Routing**: `flutter/lib/app/app_shell.dart`
- **Key Feature Screens**:
  - `Mixed Subscriptions`: `flutter/lib/features/mixed_subscriptions/mixed_subscriptions_screen.dart`
  - `Smart Groups`: `flutter/lib/features/manifest_groups/manifest_groups_screen.dart`
  - `Servers List`: `flutter/lib/features/servers/servers_screen.dart`
  - `Billing`: `flutter/lib/features/billing/billing_screen.dart`
  - `Dashboard`: `flutter/lib/features/dashboard/dashboard_screen.dart`
- **API & State Layer**:
  - Base Interface: `flutter/lib/core/api/daemon_api_base.dart`
  - Dio REST Client: `flutter/lib/core/api/daemon_api.dart`
  - Riverpod Providers: `flutter/lib/core/providers/vpn_providers.dart`
  - Theme (Atlas Dark): `flutter/lib/core/theme/atlas_theme.dart`
- **Build Output**: `flutter/build/windows/x64/runner/Release/`

#### Packaging & Installer
- **NSIS Build Script**: `installer/mosaicvpn.nsi`
- **Batch Generator**: `installer/build.bat`
- **Output Installer**: `dist/MosaicVPN-0.5.0-setup.exe`

---

### Remote Infrastructure (VPS `anenvps`)

- **Host IP**: `5.175.188.152` (Tailscale: `100.71.91.22`)
- **SSH Access**: `ssh -i ~/.ssh/id_ed25519_vitaly root@5.175.188.152`
- **Remnawave Panel Directory**: `/opt/remnawave/`
- **Remote Manifest Path**: `/opt/remnawave/manifest/provider_manifest.json`
- **Public Endpoints**:
  - Manifest URL: `https://sub.zxc1x1.ru/api/manifest.json`
  - SPA Website: `https://sub.zxc1x1.ru` (Nginx static files at `/opt/remnawave/site/`)
- **Telegram Bot**: Running in Docker / systemd (`/opt/mosaic-bot/` or similar service)

---

## ⚡ API Specification (`http://127.0.0.1:1349`)

| Endpoint | Method | Description |
|---|---|---|
| `/v1/manifest` | `GET` | Returns active provider manifest (groups, tiers, branding) |
| `/v1/groups/{id}/select` | `GET` | Auto-selects best server node in group based on strategy & health |
| `/v1/groups/{id}/health` | `GET` | Returns real-time health map (latency, alive status) |
| `/v1/pool/start` | `POST` | Triggers background ping check loop for all node pools |
| `/v1/billing/yookassa/create-payment` | `POST` | Generates YooKassa checkout URL |
| `/v1/billing/yookassa/webhook` | `POST` | Processes YooKassa payment callbacks |
| `/v1/promo/redeem` | `POST` | Redeems promo code for account extension |

---

## 📋 Active Implementation TODO List

### 1. ⚙️ Daemon (`mosaicd`)
- [ ] **Weight & Tier Balancing in Pool Engine**: Update `selectURLTest` in `internal/subs/pool.go` to compute `Score = Latency / max(Weight, 1)` and filter nodes by user tier (`free` vs `premium` vs `vip`).
- [ ] **Offline Cache Persistence**: Ensure `store.json` persists `activeManifest` so client starts smoothly without network connection.
- [ ] **Service Resolver Engine**: Implement resolution logic for `profile.services[]` (e.g. MTProto proxy picker deep links).

### 2. 📱 Flutter GUI (`MosaicBox`)
- [ ] **Simple vs Expert UI Mode**: Add a global toggle allowing users to switch between simplified zero-config mode and full expert control.
- [ ] **Remove Country Hardcode**: Replace remaining hardcoded country code mappings in `servers_screen.dart` with dynamic metadata from `provider_manifest.json`.
- [ ] **Fix Dart Analyzer Warnings**: Clean up `use_build_context_synchronously` warnings in `dashboard_screen.dart`.
- [ ] **Provider Profiles Screen**: Build dedicated screen rendering custom service cards (Telegram MTProto proxy auto-setup, support widgets).

### 3. 🌐 Web & Infrastructure
- [ ] **Site & Landing Page**: Finalize Atlas-themed landing page at `https://sub.zxc1x1.ru` with complete SEO and AI meta tags.
- [ ] **Telegram Bot Improvements**: Update referral accounting, instant tier upgrades, and automated key delivery.

### 4. 📦 Packaging
- [ ] **NSIS Installer Auto-Update**: Add background update checking and auto-download in `mosaicd`.

---

## 🛠️ Verification & Build Commands

```bash
# 1. Test Go Daemon backend
cd /c/Users/ANEN/mosaicvpn && go test ./internal/subs/ ./internal/api/

# 2. Build Go Daemon & CLI binaries
cd /c/Users/ANEN/mosaicvpn && go build -o build/mosaicd.exe ./cmd/mosaicd && go build -o build/mosaic.exe ./cmd/mosaic

# 3. Analyze Flutter codebase
export PATH="/c/Users/ANEN/flutter-sdk/bin:$PATH"
cd /c/Users/ANEN/mosaicvpn/flutter && dart analyze lib/

# 4. Build Flutter Windows App
export PATH="/c/Users/ANEN/flutter-sdk/bin:$PATH"
cd /c/Users/ANEN/mosaicvpn/flutter && flutter build windows --release

# 5. Compile NSIS Setup Package
"/c/Program Files (x86)/NSIS/makensis.exe" /c/Users/ANEN/mosaicvpn/installer/mosaicvpn.nsi
```
