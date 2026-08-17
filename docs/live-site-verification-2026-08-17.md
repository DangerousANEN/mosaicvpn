# Live site verification — 2026-08-17

Checked `https://sub.zxc1x1.ru/?v=0.3.12-validation` after VPS deployment.

Observed public download cards:

- Windows: `v0.3.12 validation`, EXE + ZIP, links to the prerelease assets.
- Linux: `v0.3.12 validation`, DEB + TAR.GZ, links to the prerelease assets.
- Android: `v0.3.12 validation`, APK, link to the prerelease asset.

The page no longer shows the old `v0.3.11` download URLs in the download section. Deployment backed up the previous `/etc/letsencrypt/landing` contents under `/root/mosaic-site-backups/` and passed nginx configuration validation before restarting the `remnawave-nginx` container.

The current release remains intentionally labelled validation/prerelease; physical Windows and Android tunnel smoke tests and final owner sign-off are still required.
