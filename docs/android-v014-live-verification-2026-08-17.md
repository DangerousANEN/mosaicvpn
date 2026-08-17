# Android v0.3.14 live verification — 2026-08-17

The public landing page at `https://sub.zxc1x1.ru/?android-account-fix=1` was checked after the VPS deployment.

The Android card now displays:

- `v0.3.14 account fix`;
- a CI-signed APK label;
- the direct download URL:
  `https://github.com/DangerousANEN/mosaicvpn/releases/download/v0.3.14-android-account-subscription-fix/MosaicVPN-Android-v0.3.14-android-account-subscription-fix.apk`.

The bot backend was backed up and deployed to `/opt/mosaic-bot/bot.py`; `mosaic-bot.service` restarted successfully. The public `/api/link/redeem` handler returns the expected 404 JSON response for an intentionally invalid code, and the authenticated subscription URL used for parsing returned HTTP 200.

The release is CI-built and signed. Physical Android install, code redemption, subscription import, setting persistence and tunnel connection still require confirmation on a device.
