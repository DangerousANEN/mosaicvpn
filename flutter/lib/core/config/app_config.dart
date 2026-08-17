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
  static const Duration statusPollInterval = Duration(seconds: 2);
  static const Duration statsPollInterval = Duration(seconds: 3);
  static const Duration logsPollInterval = Duration(seconds: 1);

  // ── MCP ──
  static const int defaultMcpPort = 9090;
  static const String defaultMcpHost = '127.0.0.1';

  // ── Proxy defaults ──
  static const String defaultSocksHost = '127.0.0.1';
  static const int defaultSocksPort = 1080;
  static const String defaultHttpHost = '127.0.0.1';
  static const int defaultHttpPort = 2080;

  // ── App metadata ──
  static const String appName = 'MosaicVPN';
  static const String appVersion = '0.3.17';
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
