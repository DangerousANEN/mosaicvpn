import 'server.dart';

/// VPN status response from the daemon.
/// Matches Go: proto.VpnStatus
class VpnStatus {
  final bool agentConnected; // daemon is reachable
  final String state; // "connected" | "connecting" | "disconnected" | "error"
  final String tunnelMode; // "tun" | "proxy"
  final bool killSwitch;
  final bool allowLAN;
  final Server? server; // current connected server
  /// Virtual Smart Group that resolved the current server. This is supplied by
  /// the daemon and never exposes a private pool member to the interface.
  final String activeGroupId;
  final String proxySocks; // e.g. "127.0.0.1:1080"
  final String proxyHTTP; // e.g. "127.0.0.1:1081"
  final int latencyMS;
  final int bytesIn;
  final int bytesOut;
  final String lastError;
  final DateTime? connectedSince;
  /// True when the daemon process carries an administrator token. Only the
  /// daemon's token decides whether TUN can start: a GUI launched as admin
  /// can still be attached to an older non-elevated daemon.
  final bool daemonElevated;

  VpnStatus({
    this.agentConnected = false,
    this.state = 'disconnected',
    this.tunnelMode = 'tun',
    this.killSwitch = true,
    this.allowLAN = true,
    this.server,
    this.activeGroupId = '',
    this.proxySocks = '',
    this.proxyHTTP = '',
    this.latencyMS = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.lastError = '',
    this.connectedSince,
    this.daemonElevated = false,
  });

  factory VpnStatus.fromJson(Map<String, dynamic> j) => VpnStatus(
        agentConnected: j['agent_connected'] ?? false,
        state: j['state'] ?? 'disconnected',
        tunnelMode: j['tunnel_mode'] ?? 'tun',
        killSwitch: j['kill_switch'] ?? true,
        allowLAN: j['allow_lan'] ?? true,
        server: j['server'] != null ? Server.fromJson(j['server']) : null,
        activeGroupId: j['active_group_id'] ?? '',
        proxySocks: j['proxy_socks'] ?? '',
        proxyHTTP: j['proxy_http'] ?? '',
        latencyMS: j['latency_ms'] ?? 0,
        bytesIn: j['bytes_in'] ?? 0,
        bytesOut: j['bytes_out'] ?? 0,
        lastError: j['last_error'] ?? '',
        connectedSince: j['connected_since'] != null
            ? DateTime.tryParse(j['connected_since'])
            : null,
        daemonElevated: j['daemon_elevated'] ?? false,
      );

  bool get isConnected => state == 'connected';
  bool get isConnecting => state == 'connecting';
  bool get isDisconnected => state == 'disconnected';
  bool get hasError => state == 'error' || lastError.isNotEmpty;

  VpnStatus copyWith({
    bool? agentConnected,
    String? state,
    String? tunnelMode,
    bool? killSwitch,
    bool? allowLAN,
    Server? server,
    String? activeGroupId,
    String? proxySocks,
    String? proxyHTTP,
    int? latencyMS,
    int? bytesIn,
    int? bytesOut,
    String? lastError,
    DateTime? connectedSince,
  }) {
    return VpnStatus(
      agentConnected: agentConnected ?? this.agentConnected,
      state: state ?? this.state,
      tunnelMode: tunnelMode ?? this.tunnelMode,
      killSwitch: killSwitch ?? this.killSwitch,
      allowLAN: allowLAN ?? this.allowLAN,
      server: server ?? this.server,
      activeGroupId: activeGroupId ?? this.activeGroupId,
      proxySocks: proxySocks ?? this.proxySocks,
      proxyHTTP: proxyHTTP ?? this.proxyHTTP,
      latencyMS: latencyMS ?? this.latencyMS,
      bytesIn: bytesIn ?? this.bytesIn,
      bytesOut: bytesOut ?? this.bytesOut,
      lastError: lastError ?? this.lastError,
      connectedSince: connectedSince ?? this.connectedSince,
    );
  }
}
