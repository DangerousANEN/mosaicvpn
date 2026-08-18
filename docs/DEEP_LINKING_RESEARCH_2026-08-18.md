# Deep-linking research — 2026-08-18

## Authoritative findings

The existing `mosaicvpn://enroll/callback` custom-scheme design is not sufficient as the primary website-to-app enrollment mechanism. Chrome documents that external application launches must originate from a user gesture and that `intent:` links are the supported Android browser mechanism; a JavaScript timer or any navigation that the browser treats as lacking a user gesture will not launch an external app. The documented `intent:` format also supports a browser fallback URL.

Android documentation recommends verified HTTPS App Links for a domain owned by the application operator. The Android application must declare an `android:autoVerify="true"` VIEW/DEFAULT/BROWSABLE intent filter for the HTTPS host, while the site must serve `/.well-known/assetlinks.json` containing the application ID and signing certificate SHA-256 fingerprint. Android 12+ then opens verified links directly in the app rather than the browser. The verification state must be tested with `adb shell pm get-app-links PACKAGE_NAME` on a real device.

Flutter documents that deep-link behavior differs for cold starts and launched applications. The app must initialise its listener early enough to receive the initial URI as well as subsequent events. The `app_links` package provides an actively maintained cross-platform abstraction for HTTPS App Links and custom schemes across Android, Windows and Linux.

Windows and Linux require their own protocol-registration paths. The current source has Android callback handling but no desktop protocol registration. On Windows, unpackaged desktop builds require URI protocol registration and must process activation/single-instance forwarding. On Linux, a `.desktop` handler with `x-scheme-handler/mosaicvpn` is required. The `app_links` documentation and its platform examples cover desktop URI handling; the `protocol_handler` example further demonstrates Windows single-instance message forwarding.

## Source URLs

1. https://developer.chrome.com/docs/android/intents
2. https://developer.android.com/training/app-links/create-deeplinks
3. https://developer.android.com/training/app-links/verify-applinks
4. https://docs.flutter.dev/ui/navigation/deep-linking
5. https://docs.flutter.dev/cookbook/navigation/set-up-app-links
6. https://pub.dev/packages/app_links
7. https://github.com/leanflutter/protocol_handler
8. https://learn.microsoft.com/en-us/windows/apps/develop/launch/handle-uri-activation

## Engineering direction

Implement verified HTTPS App Links at `sub.zxc1x1.ru` as the primary Android enrollment transport. The website will redirect to an HTTPS callback that carries only an opaque, short-lived, single-use enrollment code and state. Keep `mosaicvpn://` only as a controlled fallback. Add an early cross-platform URI listener in Flutter, complete the enrollment exchange exactly once, and show user-visible success/failure states. Add Windows and Linux protocol registration as part of installer packaging; release artifacts must be rebuilt before desktop enrollment is claimed as supported.

## Current MosaicVPN audit

The audit confirms that the current app is not registered for verified HTTPS App Links. Android declares only custom `mosaicvpn://auth/callback` and `mosaicvpn://enroll/callback` filters. It has no `android:autoVerify="true"` HTTPS filter, and production currently returns HTTP 502 for `https://sub.zxc1x1.ru/.well-known/assetlinks.json`; therefore a verified Android web-to-app flow cannot work today.

The Flutter project contains no `app_links`, `protocol_handler`, `uni_links`, `msix` or `win32_registry` dependency. Windows source has no protocol activation forwarding or registration. Linux source has no URI handler registration or `G_APPLICATION_HANDLES_OPEN` configuration. Thus, website enrollment should not currently be claimed to work on Windows or Linux.

Android native code correctly preserves custom-scheme enrollment callbacks in a separate slot and emits a MethodChannel event for an already running activity. Flutter app shell consumes the callback on startup, resume and live event, then posts the one-time code/state to `/api/app-auth/exchange`; the account service verifies that its server response has `purpose: enroll`. The App Link implementation can reuse that exchange path after extending the URI allowlist to the controlled HTTPS callback host/path.

The currently published v0.3.20 Android APK is signed by `CN=MosaicVPN, OU=Client Applications, O=MosaicVPN, C=RU`. Its APK signing certificate SHA-256 digest is `7E:22:2C:E3:6E:18:E8:A2:79:95:05:80:8E:03:7B:8F:8A:BB:B9:BE:B3:67:12:33:68:C4:DB:DB:28:6A:F7:4A`. This is the certificate fingerprint to use in the initial `assetlinks.json` entry for application ID `ru.mosaicvpn.mosaic_vpn` after reconfirming the manifest application ID for the published artifact.
