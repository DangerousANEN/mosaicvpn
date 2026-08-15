import 'package:flutter/foundation.dart';

/// Platform capability flags used to gate desktop-only plugins.
///
/// `kIsWeb` alone is not a sufficient guard: plugins such as `window_manager`
/// and `system_tray` are desktop-only, so on Android/iOS a `!kIsWeb` check
/// still lets the call through and throws MissingPluginException at startup.
/// Always gate those calls on [isDesktop].
class AppPlatform {
  const AppPlatform._();

  /// True on Windows, macOS and Linux desktop targets.
  ///
  /// Uses [defaultTargetPlatform] rather than `dart:io`'s `Platform` so this
  /// stays safe to evaluate on web, where `dart:io` is unavailable.
  static bool get isDesktop {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// True only for the Android native VpnService runtime.
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True on Android and iOS.
  static bool get isMobile {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// True when `dart:io` APIs (File, Process, Platform.environment) are usable.
  static bool get hasFileSystem => !kIsWeb;
}
