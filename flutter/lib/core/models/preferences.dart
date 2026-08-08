/// User preferences for the daemon.
/// Matches Go: store.Prefs
class Preferences {
  final String tunnelMode; // "tun" | "proxy"
  final String tunStack; // "system" | "gvisor" | "mixed" (TUN only)
  final String socksAddr;
  final String httpAddr;
  final int mixedPort; // proxy mode: single mixed port (SOCKS5+HTTP)
  final int mtu;
  final bool killSwitch;
  final bool allowLAN;
  final List<String> bypassProcesses;
  final bool blockIPv6;
  final String dnsMode; // "fake-ip" | "real-ip"
  final String dnsProxied;
  final String dnsDirect;
  final bool shareLAN;
  final String shareAddr;
  final List<String> shareAllow;
  final String autoStart; // "service" | "user" | "manual"
  final bool autoConnect;
  final bool showOnLaunch;
  final bool mcpEnabled;
  final String mcpAddr;
  final String mcpPermission; // "read" | "connect" | "full"
  final bool mcpConfirm;
  final bool showRawNodes; // Smart Presets vs Direct Raw Nodes mode
  final bool advancedMode; // Simple Mode (4 tabs) vs Advanced Mode (12 tabs)
  final String lastServerID; // q3: last connected server for auto-reconnect
  final String themeMode; // q8: "system" | "light" | "dark"
  final List<String> favoriteServerIDs; // q7: starred servers
  final bool minimizeToTray; // q9: minimize to system tray
  final bool autoConnectEgresses; // q4: auto-start egress listeners on launch
  final String testUrl; // URL used for test latency / ping
  final bool alwaysRunAsAdmin; // Always prompt UAC to run as administrator

  // ── Phase 2 additions ──────────────────────────────────────────────
  final String pingMethod; // "url" | "tcp" | "icmp" (q2)
  final String routingMode; // "global" | "rule" | "direct" (Phase 2.5)
  final String
      tlsFingerprint; // "chrome" | "firefox" | "safari" | "random" | "none"
  final bool muxEnabled; // multiplexing toggle
  final int muxConcurrency; // 0 = auto, else stream count (8..128)
  final bool tcpKeepAlive; // send keep-alive on idle
  final int tcpFastOpen; // 0 = off, 1 = on
  final int fragmentStrategy; // 0 = off, 1 = size, 2 = tls-sni
  final int fragmentSizeMin; // bytes
  final int fragmentSizeMax; // bytes
  final bool fragmentationDefense; // anti-DPI fragmentation toggle
  final List<String> splitTunnelApps; // process names excluded from VPN
  final List<String> splitTunnelDomains; // domains routed outside VPN
  final String splitTunnelMode; // "off" | "exclude" | "include"
  final String dnsProvider; // DoH/DoT URL, overrides dnsProxied when non-empty
  final String coreEngine; // "sing-box" | "xray-core" | "auto"
  final String language; // "system" | "en" | "ru"
  final bool compactMode; // dense UI mode for small displays
  final bool autoUpdateGeo; // auto-update GeoIP/GeoSite rule sets
  final int connectTimeout; // seconds (>0)
  final int readTimeout; // seconds (>0)
  final int writeTimeout; // seconds (>0)
  final int maxRetries; // dial retries
  final int concurrentDials; // parallel dials for "chain" / multi-IP servers

  // ── Phase 2.5: Backup / Restore ────────────────────────────────────
  final bool backupEnabled; // auto-backup on changes
  final String backupPath; // absolute path to export directory
  final int autoBackupInterval; // hours between auto-backups (0 = manual only)
  final bool
      includeSubscriptions; // include subscription URLs in export (sensitive)

  Preferences({
    this.tunnelMode = 'tun',
    this.tunStack = 'system',
    this.socksAddr = '127.0.0.1:1080',
    this.httpAddr = '127.0.0.1:1081',
    this.mixedPort = 2080,
    this.mtu = 1420,
    this.killSwitch = true,
    this.allowLAN = true,
    this.bypassProcesses = const [],
    this.blockIPv6 = false,
    this.dnsMode = 'fake-ip',
    this.dnsProxied = 'https://1.1.1.1/dns-query',
    this.dnsDirect = 'udp://77.88.8.8',
    this.shareLAN = false,
    this.shareAddr = '0.0.0.0:1080',
    this.shareAllow = const [],
    this.autoStart = 'service',
    this.autoConnect = true,
    this.showOnLaunch = true,
    this.mcpEnabled = true,
    this.mcpAddr = '127.0.0.1:8731',
    this.mcpPermission = 'connect',
    this.mcpConfirm = true,
    this.showRawNodes = false,
    this.advancedMode = false,
    this.lastServerID = '',
    this.themeMode = 'system',
    this.favoriteServerIDs = const [],
    this.minimizeToTray = false,
    this.autoConnectEgresses = true,
    this.testUrl = 'http://cp.cloudflare.com/generate_204',
    this.alwaysRunAsAdmin = false,
    // ── Phase 2 defaults ──
    this.pingMethod = 'url',
    this.routingMode = 'rule',
    this.tlsFingerprint = 'chrome',
    this.muxEnabled = false,
    this.muxConcurrency = 0,
    this.tcpKeepAlive = true,
    this.tcpFastOpen = 0,
    this.fragmentStrategy = 0,
    this.fragmentSizeMin = 1,
    this.fragmentSizeMax = 100,
    this.fragmentationDefense = false,
    this.splitTunnelApps = const [],
    this.splitTunnelDomains = const [],
    this.splitTunnelMode = 'off',
    this.dnsProvider = '',
    this.coreEngine = 'sing-box',
    this.language = 'system',
    this.compactMode = false,
    this.autoUpdateGeo = true,
    this.connectTimeout = 15,
    this.readTimeout = 30,
    this.writeTimeout = 30,
    this.maxRetries = 3,
    this.concurrentDials = 1,
    // ── Phase 2.5: Backup / Restore defaults ──
    this.backupEnabled = false,
    this.backupPath = '',
    this.autoBackupInterval = 0,
    this.includeSubscriptions = true,
  });

  factory Preferences.fromJson(Map<String, dynamic> j) => Preferences(
        tunnelMode: j['tunnel_mode'] ?? 'tun',
        tunStack: j['tun_stack'] ?? 'system',
        socksAddr: j['socks_addr'] ?? '127.0.0.1:1080',
        httpAddr: j['http_addr'] ?? '127.0.0.1:1081',
        mixedPort: j['mixed_port'] ?? 2080,
        mtu: j['mtu'] ?? 1420,
        killSwitch: j['kill_switch'] ?? true,
        allowLAN: j['allow_lan'] ?? true,
        bypassProcesses: (j['bypass_processes'] as List?)?.cast<String>() ?? [],
        blockIPv6: j['block_ipv6'] ?? false,
        dnsMode: j['dns_mode'] ?? 'fake-ip',
        dnsProxied: j['dns_proxied'] ?? 'https://1.1.1.1/dns-query',
        dnsDirect: j['dns_direct'] ?? 'udp://77.88.8.8',
        shareLAN: j['share_lan'] ?? false,
        shareAddr: j['share_addr'] ?? '0.0.0.0:1080',
        shareAllow: (j['share_allow'] as List?)?.cast<String>() ?? [],
        autoStart: j['auto_start'] ?? 'service',
        autoConnect: j['auto_connect'] ?? true,
        showOnLaunch: j['show_on_launch'] ?? true,
        mcpEnabled: j['mcp_enabled'] ?? true,
        mcpAddr: j['mcp_addr'] ?? '127.0.0.1:8731',
        mcpPermission: j['mcp_permission'] ?? 'connect',
        mcpConfirm: j['mcp_confirm'] ?? true,
        showRawNodes: j['show_raw_nodes'] ?? false,
        advancedMode: j['advanced_mode'] ?? false,
        lastServerID: j['last_server_id'] ?? '',
        themeMode: j['theme_mode'] ?? 'system',
        favoriteServerIDs:
            (j['favorite_server_ids'] as List?)?.cast<String>() ?? [],
        minimizeToTray: j['minimize_to_tray'] ?? false,
        autoConnectEgresses: j['auto_connect_egresses'] ?? true,
        testUrl: j['test_url'] ?? 'http://cp.cloudflare.com/generate_204',
        alwaysRunAsAdmin: j['always_run_as_admin'] ?? false,
        pingMethod: j['ping_method'] ?? 'url',
        routingMode: j['routing_mode'] ?? 'rule',
        tlsFingerprint: j['tls_fingerprint'] ?? 'chrome',
        muxEnabled: j['mux_enabled'] ?? false,
        muxConcurrency: j['mux_concurrency'] ?? 0,
        tcpKeepAlive: j['tcp_keep_alive'] ?? true,
        tcpFastOpen: j['tcp_fast_open'] ?? 0,
        fragmentStrategy: j['fragment_strategy'] ?? 0,
        fragmentSizeMin: j['fragment_size_min'] ?? 1,
        fragmentSizeMax: j['fragment_size_max'] ?? 100,
        fragmentationDefense: j['fragmentation_defense'] ?? false,
        splitTunnelApps:
            (j['split_tunnel_apps'] as List?)?.cast<String>() ?? [],
        splitTunnelDomains:
            (j['split_tunnel_domains'] as List?)?.cast<String>() ?? [],
        splitTunnelMode: j['split_tunnel_mode'] ?? 'off',
        dnsProvider: j['dns_provider'] ?? '',
        coreEngine: j['core_engine'] ?? 'sing-box',
        language: j['language'] ?? 'system',
        compactMode: j['compact_mode'] ?? false,
        autoUpdateGeo: j['auto_update_geo'] ?? true,
        connectTimeout: j['connect_timeout'] ?? 15,
        readTimeout: j['read_timeout'] ?? 30,
        writeTimeout: j['write_timeout'] ?? 30,
        maxRetries: j['max_retries'] ?? 3,
        concurrentDials: j['concurrent_dials'] ?? 1,
        backupEnabled: j['backup_enabled'] ?? false,
        backupPath: j['backup_path'] ?? '',
        autoBackupInterval: j['auto_backup_interval'] ?? 0,
        includeSubscriptions: j['include_subscriptions'] ?? true,
      );

  Map<String, dynamic> toJson() => {
        'tunnel_mode': tunnelMode,
        'tun_stack': tunStack,
        'socks_addr': socksAddr,
        'http_addr': httpAddr,
        'mixed_port': mixedPort,
        'mtu': mtu,
        'kill_switch': killSwitch,
        'allow_lan': allowLAN,
        'bypass_processes': bypassProcesses,
        'block_ipv6': blockIPv6,
        'dns_mode': dnsMode,
        'dns_proxied': dnsProxied,
        'dns_direct': dnsDirect,
        'share_lan': shareLAN,
        'share_addr': shareAddr,
        'share_allow': shareAllow,
        'auto_start': autoStart,
        'auto_connect': autoConnect,
        'show_on_launch': showOnLaunch,
        'mcp_enabled': mcpEnabled,
        'mcp_addr': mcpAddr,
        'mcp_permission': mcpPermission,
        'mcp_confirm': mcpConfirm,
        'show_raw_nodes': showRawNodes,
        'advanced_mode': advancedMode,
        'last_server_id': lastServerID,
        'theme_mode': themeMode,
        'favorite_server_ids': favoriteServerIDs,
        'minimize_to_tray': minimizeToTray,
        'auto_connect_egresses': autoConnectEgresses,
        'test_url': testUrl,
        'always_run_as_admin': alwaysRunAsAdmin,
        'ping_method': pingMethod,
        'routing_mode': routingMode,
        'tls_fingerprint': tlsFingerprint,
        'mux_enabled': muxEnabled,
        'mux_concurrency': muxConcurrency,
        'tcp_keep_alive': tcpKeepAlive,
        'tcp_fast_open': tcpFastOpen,
        'fragment_strategy': fragmentStrategy,
        'fragment_size_min': fragmentSizeMin,
        'fragment_size_max': fragmentSizeMax,
        'fragmentation_defense': fragmentationDefense,
        'split_tunnel_apps': splitTunnelApps,
        'split_tunnel_domains': splitTunnelDomains,
        'split_tunnel_mode': splitTunnelMode,
        'dns_provider': dnsProvider,
        'core_engine': coreEngine,
        'language': language,
        'compact_mode': compactMode,
        'auto_update_geo': autoUpdateGeo,
        'connect_timeout': connectTimeout,
        'read_timeout': readTimeout,
        'write_timeout': writeTimeout,
        'max_retries': maxRetries,
        'concurrent_dials': concurrentDials,
        'backup_enabled': backupEnabled,
        'backup_path': backupPath,
        'auto_backup_interval': autoBackupInterval,
        'include_subscriptions': includeSubscriptions,
      };

  Preferences copyWith({
    String? tunnelMode,
    String? tunStack,
    String? socksAddr,
    String? httpAddr,
    int? mixedPort,
    int? mtu,
    bool? killSwitch,
    bool? allowLAN,
    List<String>? bypassProcesses,
    bool? blockIPv6,
    String? dnsMode,
    String? dnsProxied,
    String? dnsDirect,
    bool? shareLAN,
    String? shareAddr,
    List<String>? shareAllow,
    String? autoStart,
    bool? autoConnect,
    bool? showOnLaunch,
    bool? mcpEnabled,
    String? mcpAddr,
    String? mcpPermission,
    bool? mcpConfirm,
    bool? showRawNodes,
    bool? advancedMode,
    String? lastServerID,
    String? themeMode,
    List<String>? favoriteServerIDs,
    bool? minimizeToTray,
    bool? autoConnectEgresses,
    String? testUrl,
    bool? alwaysRunAsAdmin,
    String? pingMethod,
    String? routingMode,
    String? tlsFingerprint,
    bool? muxEnabled,
    int? muxConcurrency,
    bool? tcpKeepAlive,
    int? tcpFastOpen,
    int? fragmentStrategy,
    int? fragmentSizeMin,
    int? fragmentSizeMax,
    bool? fragmentationDefense,
    List<String>? splitTunnelApps,
    List<String>? splitTunnelDomains,
    String? splitTunnelMode,
    String? dnsProvider,
    String? coreEngine,
    String? language,
    bool? compactMode,
    bool? autoUpdateGeo,
    int? connectTimeout,
    int? readTimeout,
    int? writeTimeout,
    int? maxRetries,
    int? concurrentDials,
    bool? backupEnabled,
    String? backupPath,
    int? autoBackupInterval,
    bool? includeSubscriptions,
  }) =>
      Preferences(
        tunnelMode: tunnelMode ?? this.tunnelMode,
        tunStack: tunStack ?? this.tunStack,
        socksAddr: socksAddr ?? this.socksAddr,
        httpAddr: httpAddr ?? this.httpAddr,
        mixedPort: mixedPort ?? this.mixedPort,
        mtu: mtu ?? this.mtu,
        killSwitch: killSwitch ?? this.killSwitch,
        allowLAN: allowLAN ?? this.allowLAN,
        bypassProcesses: bypassProcesses ?? this.bypassProcesses,
        blockIPv6: blockIPv6 ?? this.blockIPv6,
        dnsMode: dnsMode ?? this.dnsMode,
        dnsProxied: dnsProxied ?? this.dnsProxied,
        dnsDirect: dnsDirect ?? this.dnsDirect,
        shareLAN: shareLAN ?? this.shareLAN,
        shareAddr: shareAddr ?? this.shareAddr,
        shareAllow: shareAllow ?? this.shareAllow,
        autoStart: autoStart ?? this.autoStart,
        autoConnect: autoConnect ?? this.autoConnect,
        showOnLaunch: showOnLaunch ?? this.showOnLaunch,
        mcpEnabled: mcpEnabled ?? this.mcpEnabled,
        mcpAddr: mcpAddr ?? this.mcpAddr,
        mcpPermission: mcpPermission ?? this.mcpPermission,
        mcpConfirm: mcpConfirm ?? this.mcpConfirm,
        showRawNodes: showRawNodes ?? this.showRawNodes,
        advancedMode: advancedMode ?? this.advancedMode,
        lastServerID: lastServerID ?? this.lastServerID,
        themeMode: themeMode ?? this.themeMode,
        favoriteServerIDs: favoriteServerIDs ?? this.favoriteServerIDs,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        autoConnectEgresses: autoConnectEgresses ?? this.autoConnectEgresses,
        testUrl: testUrl ?? this.testUrl,
        alwaysRunAsAdmin: alwaysRunAsAdmin ?? this.alwaysRunAsAdmin,
        pingMethod: pingMethod ?? this.pingMethod,
        routingMode: routingMode ?? this.routingMode,
        tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
        muxEnabled: muxEnabled ?? this.muxEnabled,
        muxConcurrency: muxConcurrency ?? this.muxConcurrency,
        tcpKeepAlive: tcpKeepAlive ?? this.tcpKeepAlive,
        tcpFastOpen: tcpFastOpen ?? this.tcpFastOpen,
        fragmentStrategy: fragmentStrategy ?? this.fragmentStrategy,
        fragmentSizeMin: fragmentSizeMin ?? this.fragmentSizeMin,
        fragmentSizeMax: fragmentSizeMax ?? this.fragmentSizeMax,
        fragmentationDefense: fragmentationDefense ?? this.fragmentationDefense,
        splitTunnelApps: splitTunnelApps ?? this.splitTunnelApps,
        splitTunnelDomains: splitTunnelDomains ?? this.splitTunnelDomains,
        splitTunnelMode: splitTunnelMode ?? this.splitTunnelMode,
        dnsProvider: dnsProvider ?? this.dnsProvider,
        coreEngine: coreEngine ?? this.coreEngine,
        language: language ?? this.language,
        compactMode: compactMode ?? this.compactMode,
        autoUpdateGeo: autoUpdateGeo ?? this.autoUpdateGeo,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        readTimeout: readTimeout ?? this.readTimeout,
        writeTimeout: writeTimeout ?? this.writeTimeout,
        maxRetries: maxRetries ?? this.maxRetries,
        concurrentDials: concurrentDials ?? this.concurrentDials,
        backupEnabled: backupEnabled ?? this.backupEnabled,
        backupPath: backupPath ?? this.backupPath,
        autoBackupInterval: autoBackupInterval ?? this.autoBackupInterval,
        includeSubscriptions: includeSubscriptions ?? this.includeSubscriptions,
      );
}

/// Core engine info (sing-box, xray, etc.)
class CoreInfo {
  final String name;
  final String version;
  final String path;
  final bool active;

  CoreInfo({
    this.name = '',
    this.version = '',
    this.path = '',
    this.active = false,
  });

  factory CoreInfo.fromJson(Map<String, dynamic> j) => CoreInfo(
        name: j['name'] ?? '',
        version: j['version'] ?? '',
        path: j['path'] ?? '',
        active: j['active'] ?? false,
      );
}
