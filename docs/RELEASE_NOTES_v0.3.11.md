# MosaicVPN v0.3.11

## What changed

This release unifies the current Windows, Linux, and Android clients around the same MosaicVPN account flow and runtime packaging model. Desktop launchers now resolve `mosaicd` from portable and installed locations without relying on a developer-machine path. Linux portable and DEB builds bundle the MosaicVPN UI, `mosaicd`, CLI utility, and verified sing-box runtime.

Android now builds the GPLv3 sing-box/libbox runtime from the pinned upstream revision and packages `libbox.so` for `arm64-v8a`, `armeabi-v7a`, and `x86_64`. The APK packaging pipeline includes a guard that fails the build if the native runtime is absent. The Android app is branded as MosaicVPN and uses the real native VPN bridge rather than a mock provider.

The client interface includes the Mosaic tray control center, close-to-tray by default with an explicit full-quit action, Russian and English localization updates, theme consistency fixes, and a corrected desktop daemon discovery path.

## Validation completed

The release commit passed the GitHub Actions preflight for all three targets. Windows portable and Setup builds succeeded. Linux portable and DEB builds succeeded. Android source-first multi-ABI runtime compilation and debug APK validation succeeded, including the embedded-libbox guard. Static analysis and the Flutter test suite also passed locally.

## Important notes

This release contains no bundled demonstration subscriptions or demo server lists. Account information and subscription routes are obtained from the authenticated service APIs. The client deliberately does not expose internal pool servers; users select service-provided groups and permitted standalone routes only.

The Android APK is signed by the configured release signing identity during the tagged build. On Android, installation from a browser may require allowing installation from the selected source in the operating-system settings.
