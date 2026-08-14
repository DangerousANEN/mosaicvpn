# MosaicVPN Android Technical Preview

The signed Android APK is a **technical preview** of the Flutter client. It provides the branded MosaicVPN application shell, account flow, interface localization, light/dark themes, and the platform packaging needed to test installation and future upgrade continuity.

## What is verified

| Area | Status |
|---|---|
| APK installation package | Signed with the MosaicVPN Android release key |
| Application name and launcher icon | Branded as MosaicVPN with an adaptive Android icon |
| Flutter UI | Built on the native Android CI runner |
| Update identity | Stable keystore, alias `mosaicvpn-release` |

## Current limitation

The technical preview does **not** yet bundle a functioning Android system tunnel runtime. A full implementation needs Android `VpnService` plus a compliant native engine integration. The official sing-box `libbox` runtime is GPLv3-or-later; it must not be linked or distributed in MosaicVPN until the client licensing, source availability and compliance material have been finalized.

The APK must therefore not be described as a finished Android VPN application, and it must not be used to claim a working system-level tunnel.

## Next engineering milestone

The next milestone is a separately reviewed, GPL-compliant Android `VpnService`/libbox integration, with a physical-device test covering permission, foreground notification, connection, reconnect, disconnect and cleanup.
