# MosaicVPN Flutter — Architecture

## Stack
- **Framework:** Flutter 3.x (Skia/Impeller, no Chromium)
- **Language:** Dart
- **State management:** Riverpod 2.x (code-gen with `@riverpod`)
- **Routing:** GoRouter
- **HTTP:** Dio (interceptors, retry, timeout)
- **VPN cores:** sing-box + xray (managed as child processes)
- **SVG:** flutter_svg (world map) + custom GestureDetector overlay
- **System tray:** system_tray (Win/Linux) + tray_manager
- **Storage:** SharedPreferences (prefs) + Hive (server cache, profiles)
- **Platform channels:** MethodChannel for Android VPN Service

## Targets
| Platform | Renderer   | VPN integration         |
|----------|-----------|-------------------------|
| Windows  | Impeller  | Process.start() cores   |
| Linux    | Impeller  | Process.start() cores   |
| Android  | Impeller  | VpnService + tun2socks  |

## Daemon API (inherited from Rust version)
Base: `http://127.0.0.1:8080`
- `GET  /v1/status`
- `POST /v1/connect`        `{"server_id": "..."}`
- `POST /v1/disconnect`
- `GET  /v1/servers`
- `GET  /v1/subscriptions`
- `POST /v1/subscriptions`
- `DELETE /v1/subscriptions/:id`
- `POST /v1/subscriptions/:id/refresh`
- `GET  /v1/preferences`
- `PUT  /v1/preferences`
- `GET  /v1/rules`
- `GET  /v1/egress`
- `GET  /v1/cores`
- `GET  /v1/anti-dpi`
- `PUT  /v1/anti-dpi`
