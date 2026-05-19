# MosaicVPN Service Project

## Overview

MosaicVPN is an open-source cross-platform VPN client built on [sing-box](https://github.com/SagerNet/sing-box) 1.13+. It provides a modern UI (React + Tauri), CLI interface, and MCP server for AI agent integration.

## Current Status (rc53-leak-rufix)

- **Latest release:** v1.0.0-rc53
- **Backend:** Go 1.23+ with embedded sing-box 1.13.5
- **Frontend:** React 18 + TypeScript + Vite
- **Desktop:** Tauri 2.0 (Windows, macOS, Linux)
- **Mobile:** Android (APK), iOS (TestFlight)

## Project TODO

### Critical (Blockers)
- [ ] **TUN mode fix** — `auto_redirect` added for Windows; needs testing on real hardware
- [ ] **Anti-DPI validation** — settings apply correctly but user reports they "don't work"; needs protocol-specific verification
- [ ] **Memory leak (ru-fix)** — fixed in rc53, under long-running test

### Features
- [x] Ping system (replaced Test URL/TCP)
- [x] Ping method selector (TCP, URL, ICMP, Via Proxy HEAD/GET)
- [x] Naïve proxy support (parser + outbound)
- [x] Multi-format subscription parser (sing-box, Clash, v2ray, SIP008, WireGuard, AmneziaVPN)
- [x] Auto-DNS fix (rc52)
- [x] Connection leak fix (rc53)
- [x] Embedded MCP server for AI control
- [ ] iOS App Store release
- [ ] Android F-Droid repository
- [ ] Automatic updates

### Infrastructure
- [x] Download pages (web/download/)
- [ ] CI/CD pipeline (GitHub Actions)
- [ ] Code signing for Windows/macOS
- [ ] Update server

## Functionality

### Core
- **Protocols:** VLESS, Trojan, VMess, Shadowsocks, Hysteria2, Naïve, WireGuard, AmneziaWG
- **Transports:** TCP, WebSocket, gRPC, HTTP/2, XHTTP, QUIC
- **Security:** TLS, Reality, ECH, uTLS fingerprinting
- **Anti-DPI:** TLS fragment, Mux.cool, ECH, uTLS override

### Proxy Modes
- **TUN:** Full-system VPN (requires admin/root)
- **SOCKS5:** 127.0.0.1:2080 (configurable)
- **HTTP:** 127.0.0.1:2081 (configurable)
- **Mixed:** Auto-switching

### Testing
- **Ping methods:** TCP connect, HTTP 204 URL test, ICMP ping, HTTP via proxy (HEAD/GET)
- **GeoIP:** Automatic country/city resolution
- **Latency history:** Per-server sparkline graphs

### Subscription Management
- **Formats:** sing-box JSON, Clash YAML, v2ray base64, SIP008, WireGuard conf, AmneziaVPN
- **Auto-refresh:** Configurable interval
- **Traffic tracking:** Subscription-Userinfo header parsing
- **Favorites & Notes:** Local storage

## File Paths

```
mosaicvpn/
├── cmd/
│   └── mosaic/               # CLI entry point
├── internal/
│   ├── api/                  # HTTP API (server.go, handlers)
│   ├── geoip/                # IP geolocation
│   ├── logx/                 # Structured logging
│   ├── paths/                # OS-specific paths
│   ├── proto/                # Protocol types & constants
│   ├── state/                # Connection state machine
│   │   ├── singbox_backend.go    # sing-box config builder
│   │   ├── singbox_egress.go     # Egress config builder
│   │   └── state.go              # Main state manager
│   ├── store/                # JSON persistence
│   │   └── store.go              # Prefs, servers, subscriptions
│   └── subs/                 # Subscription parsers
│       ├── parser.go             # Main parser dispatcher
│       ├── singbox.go            # sing-box JSON format
│       ├── clash.go              # Clash YAML format
│       ├── v2ray.go              # v2ray base64 format
│       └── ...
├── ui/                       # React frontend
│   ├── src/
│   │   ├── screens/          # Main page components
│   │   │   ├── Folio.tsx         # Settings / Prefs
│   │   │   ├── Main.tsx          # Main dashboard
│   │   │   ├── Pool.tsx          # Server pool / subscription list
│   │   │   ├── SubscriptionDetail.tsx  # Subscription drill-down
│   │   │   └── Routing.tsx       # Route rules
│   │   ├── api/              # API client & types
│   │   ├── components/       # Reusable UI components
│   │   └── utils/            # Local storage helpers
│   └── public/               # Static assets
├── web/                      # Web assets
│   └── download/             # Download pages
├── go.mod                    # Go dependencies
├── package.json              # Node dependencies
├── Makefile                  # Build automation
└── README.md                 # User-facing docs
```

## Key Configuration

### Prefs (store.Prefs)
```go
type Prefs struct {
    TunnelMode       string  // "tun" | "socks" | "mixed"
    SOCKSAddr        string  // "127.0.0.1:2080"
    HTTPAddr         string  // "127.0.0.1:2081"
    DNSAddr          string  // "127.0.0.1:53" (TUN only)
    URLTestEndpoint  string  // "https://www.gstatic.com/generate_204"
    AutoFetchMinutes int     // 0 = disabled
    
    // Anti-DPI
    DPIFingerprint   string  // "chrome" | "firefox" | ... | "auto"
    DPIFragment      string  // "1-3" | "2-5" | "5-10"
    DPIMux           string  // "4" | "8" | "auto" | "off"
    DPIECH           bool    // Encrypted Client Hello
    
    // Ping
    PingMethod       string  // "tcp" | "url" | "icmp" | "via_proxy_head" | "via_proxy_get"
    
    // MCP
    MCPEnabled       bool
    MCPAddr          string
    MCPPermission    string  // "read" | "connect" | "full"
}
```

### API Endpoints
- `GET /v1/status` — Connection status
- `POST /v1/connect` — Connect to server
- `POST /v1/disconnect` — Disconnect
- `GET /v1/servers` — List servers
- `POST /v1/servers/{id}/ping` — Ping server (new)
- `POST /v1/servers/ping-all` — Ping all servers (new)
- `GET /v1/subscriptions` — List subscriptions
- `POST /v1/subscriptions` — Add subscription
- `GET /v1/rules` — List routing rules
- `GET /v1/prefs` / `POST /v1/prefs` — Preferences

## Build Requirements

- **Go:** 1.23+
- **Node.js:** 20+ (with pnpm or npm)
- **Tauri:** Rust toolchain
- **sing-box:** Embedded binary (auto-downloaded on first build)

## Quick Start (Development)

```bash
git clone https://github.com/DangerousANEN/mosaicvpn.git
cd mosaicvpn
git checkout rc53-leak-rufix

# Build backend
go build -o mosaic ./cmd/mosaic

# Build frontend
cd ui
npm install
npm run build

# Run desktop (dev)
npm run tauri dev

# Build desktop (release)
npm run tauri build
```

## License

GPL-3.0
