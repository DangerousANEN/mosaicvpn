# Android libbox runtime

MosaicVPN uses the official **sing-box experimental/libbox** runtime to provide Android `VpnService` support. The generated `libbox.aar` and `libbox-legacy.aar` are intentionally not committed: binary artifacts are rebuilt from the pinned GPLv3 upstream source before each Android release.

Run the following command from the repository root before building a local Android APK:

```bash
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME=/path/to/android-ndk
export JAVA_HOME=/path/to/jdk-17
./scripts/build_android_libbox.sh
```

The script builds and merges `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `x86` variants, then writes exact source revision and SHA-256 provenance to `VERSION.txt`.

> The runtime is sourced from [SagerNet/sing-box](https://github.com/SagerNet/sing-box), version 1.13.18, revision `45ca32dcb966f07f97fc888fe8586e359dbe8405`, under GPL-3.0-or-later. See the repository-level [`LICENSE`](../../../LICENSE) and [`NOTICE.md`](../../../NOTICE.md).
