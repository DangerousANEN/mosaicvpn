# Android libbox research

## Official sources

- [sing-box Android features](https://sing-box.sagernet.org/clients/android/features/)
- [Android `VpnService` reference](https://developer.android.com/reference/android/net/VpnService)
- [sing-box libbox FFI manifest](https://raw.githubusercontent.com/SagerNet/sing-box/testing/experimental/libbox/ffi.json)
- [sing-box GPL license](https://raw.githubusercontent.com/SagerNet/sing-box/testing/LICENSE)

## Findings

The official sing-box Android client uses Android `VpnService` for the unprivileged TUN implementation and a foreground service when TUN is needed. Android requires a user permission request through `VpnService.prepare`, a declared service protected by `android.permission.BIND_VPN_SERVICE`, and foreground promotion for a long-running tunnel service.

The official `experimental/libbox/ffi.json` declares an `android-main` target with generated Java bindings under the package `io.nekohasekai.libbox`. The build produces `libbox.aar`, has `min_sdk` 23 and targets Android NDK `28.0.13004108`. The listed runtime tags include gVisor, QUIC, WireGuard, uTLS, Naive outbound, Clash API and Tailscale-related functionality.

The official sing-box repository is licensed under GPLv3-or-later, with an additional restriction that a derivative work may not use the original name or imply association without consent. MosaicVPN must not copy GPL source code or publish a libbox-based Android integration until its Android client distribution and source-availability obligations have been reviewed and made compliant.

## Current decision

MosaicVPN can proceed with Android app signing and branded APK CI. A functioning system tunnel requires a compliant libbox integration or another independently licensed Android-native tunnel runtime. The current Flutter client does not yet include such a runtime, so a signed APK must be labelled as a technical preview rather than a full Android VPN release until this is resolved.
