# MosaicVPN Release Preflight — 2026-08-16

## Scope

This note records externally observed release-pipeline facts while preparing the current MosaicVPN release from `main`.

## Official Android SDK source

The Android SDK Command-Line Tools were installed locally using the official Android Developers instructions and the official download URL discovered from the Android Studio download page:

- Documentation: https://developer.android.com/tools
- Command-line tools archive: https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip

The official documentation states that `sdkmanager` installs Android SDK packages and that `ANDROID_HOME` should point to the SDK directory. The local verification installed Android platform tools, platform `android-36`, build-tools `36.0.0`, CMake `3.22.1`, and NDK `28.0.13004108`.

## GitHub Actions preflight, run 31948516723

A non-tag `MosaicVPN release` workflow dispatch was run for `main`, so it did not create a public release. Results:

| Job | Result | Finding |
|---|---|---|
| Windows portable and Setup | Success | The pipeline built Windows portable and Setup packages without a tag. |
| Linux portable and DEB | Failure | `VERSION` was `main`; `dpkg-deb` rejected it because Debian versions must start with a digit. |
| Android branding and APK validation | Failure | The pinned sing-box/libbox build completed successfully; the later `flutter build apk --debug` failed at `:app:packageDebug` with insufficient Gradle detail in the original log. |

The Linux workflow defect was fixed in commit `477ef56`: non-tag preflight now uses the numeric version from `flutter/pubspec.yaml`. The Android non-tag command now uses `flutter build apk --debug --verbose` to provide actionable packaging diagnostics.

## GitHub access state

After the above dispatch, the GitHub CLI token became invalid (`HTTP 401: Bad credentials`). The GitHub connector remains enabled in current task configuration, but Actions dispatch and log APIs cannot presently be called via `gh` until the integration token is refreshed. No historical user-provided GitHub token was used.

## Current local Android reproduction

A local source-first libbox build was launched with the installed SDK/NDK/JDK 17. It successfully progressed through the long native compilation and then entered Gradle APK build processing. The final package result is pending at the time of this note.

## References

[1] Android Developers, “Command-line tools” — https://developer.android.com/tools
[2] Android Developers, “Download Android Studio & App Tools” — https://developer.android.com/studio
[3] GitHub Actions run 31948516723 — https://github.com/DangerousANEN/mosaicvpn/actions/runs/31948516723
