import 'package:package_info_plus/package_info_plus.dart';
/// Central application configuration.
///
/// All hardcoded URLs, ports, timeouts, and paths live here so they
/// can be changed in one place instead of scattered across the codebase.
class AppConfig {
  AppConfig._();

  // ── Daemon ──
  /// Default daemon API port (HTTP).
  static const int defaultDaemonPort = 9090;

  /// Default daemon API host.
  static const String defaultDaemonHost = '127.0.0.1';

  /// Full base URL for the daemon API.
  static String get daemonBaseUrl =>
      'http://$defaultDaemonHost:$defaultDaemonPort';

  /// Daemon lockfile path (relative to user home).
  static const String lockfilePath = '.mosaic/daemon.lock';

  // ── Timeouts ──
  static const Duration connectTimeout = Duration(seconds: 5);
  static const Duration receiveTimeout = Duration(seconds: 8);
  // A live loopback daemon answers immediately; stale lockfiles should not
  // block the first frame while the launcher searches fallback locations.
  static const Duration healthCheckTimeout = Duration(milliseconds: 450);

  // ── Polling intervals ──
  /// Status polling: responsive in foreground for instant UI state changes,
  /// heavily throttled in background to save battery & CPU wakeups.
  static const Duration statusPollInterval = Duration(seconds: 2);
  static const Duration statusPollIntervalBackground = Duration(seconds: 20);
  /// Traffic stats: less critical, wider gaps acceptable.
  static const Duration statsPollInterval = Duration(seconds: 5);
  static const Duration statsPollIntervalBackground = Duration(seconds: 30);
  /// Logs: purely diagnostic, no need for tight polling.
  static const Duration logsPollInterval = Duration(seconds: 3);
  static const Duration logsPollIntervalBackground = Duration(seconds: 30);
  /// Connections table live-refresh (was hardcoded 3s inline, now named).
  static const Duration connectionsPollInterval = Duration(seconds: 3);
  /// When the app is fully backgrounded (Doze/standby), ALL polling should
  /// pause entirely to avoid CPU wakeups. This flag is checked by providers.
  static const bool suspendPollingInDoze = true;

  // ── MCP ──
  static const int defaultMcpPort = 9090;
  static const String defaultMcpHost = '127.0.0.1';

  // ── Proxy defaults ──
  static const String defaultSocksHost = '127.0.0.1';
  static const int defaultSocksPort = 1080;
  static const String defaultHttpHost = '127.0.0.1';
  static const int defaultHttpPort = 2080;

  // ── Web endpoints ──
  static const String websiteBaseUrl = 'https://sub.zxc1x1.ru';
  static const String websiteSetupUrl = 'https://sub.zxc1x1.ru/setup.html';

  // ── App metadata ──
  static const String appName = 'MosaicVPN';
  /// Fallback synced with pubspec.yaml (version: X.Y.Z+N). Resolved to the
  /// real build version from package_info_plus at runtime [resolveAppVersion].
  static const String appVersion = '0.3.71';

  /// True build version, filled once at startup by resolveAppVersion().
  static String? _resolvedAppVersion;

  /// The version the UI and the update checker must use: the real package
  /// version when available, otherwise the const fallback above.
  static String get effectiveAppVersion => _resolvedAppVersion ?? appVersion;

  /// Called once during app bootstrap to sync the version with the actual
  /// package (pubspec version + build number), so the About screen and the
  /// update dialog never drift from the built APK again.
  static Future<void> resolveAppVersion() async {
    if (_resolvedAppVersion != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _resolvedAppVersion = info.version;
    } catch (_) {
      // Keep the const fallback: package_info is unavailable (tests, fakes).
    }
  }
  static const String appAuthor = 'MosaicVPN';

  // ── Supported protocols ──
  static const List<String> supportedProtocols = [
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'wireguard',
    'socks',
    'http',
  ];

  // ── Map defaults ──
  static const double mapMinZoom = 1.0;
  static const double mapMaxZoom = 3.0;
  static const double mapDefaultZoom = 1.0;
  static const double mapPinSize = 12.0;
}
