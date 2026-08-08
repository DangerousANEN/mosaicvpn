/// A proxy listener (egress) — a local inbound port that forwards
/// traffic through a specific outbound server or chain.
///
/// In proxy mode, MosaicVPN can expose multiple listeners on different
/// ports, each routed to a different server. This lets apps configure
/// different proxies (e.g., browser → port 2080 → Frankfurt, game →
/// port 2081 → Tokyo).
class Egress {
  final String id;
  final String name;

  /// Listener protocol: 'mixed' (SOCKS5+HTTP), 'socks', 'http', 'tun'
  final String type;

  /// Bind address, usually '127.0.0.1'
  final String listen;

  /// Local port the listener binds to
  final int port;

  /// ID of the server this egress routes through (null = default/active)
  final String? serverID;

  /// Human-readable server name (denormalised for display)
  final String? serverName;

  /// ID of the manifest group this egress auto-selects from.
  /// When set, serverID is ignored and the daemon picks the best node from the pool.
  final String? groupID;

  /// Human-readable group name (denormalised for display)
  final String? groupName;

  /// Whether the listener is currently running
  final bool active;

  /// Whether traffic is flowing through this egress
  final int connections;

  /// Upload/download bytes through this egress
  final int upload;
  final int download;

  /// Whether to auto-start this egress listener when the app launches (q4)
  final bool autoConnect;

  const Egress({
    required this.id,
    required this.name,
    this.type = 'mixed',
    this.listen = '127.0.0.1',
    required this.port,
    this.serverID,
    this.serverName,
    this.groupID,
    this.groupName,
    this.active = true,
    this.connections = 0,
    this.upload = 0,
    this.download = 0,
    this.autoConnect = false,
  });

  factory Egress.fromJson(Map<String, dynamic> j) => Egress(
        id: j['id'] as String,
        name: j['name'] as String,
        type: j['type'] as String? ?? j['protocol'] as String? ?? 'mixed',
        listen: j['listen'] as String? ?? '127.0.0.1',
        port: j['port'] as int? ?? 0,
        serverID: j['server_id'] as String?,
        serverName: j['server_name'] as String?,
        groupID: j['group_id'] as String?,
        groupName: j['group_name'] as String?,
        active: j['active'] as bool? ?? true,
        connections: j['connections'] as int? ?? 0,
        upload: j['upload'] as int? ?? 0,
        download: j['download'] as int? ?? 0,
        autoConnect: j['auto_connect'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'listen': listen,
        'port': port,
        'server_id': serverID,
        'server_name': serverName,
        'group_id': groupID,
        'group_name': groupName,
        'active': active,
        'connections': connections,
        'upload': upload,
        'download': download,
        'auto_connect': autoConnect,
      };

  Egress copyWith({
    String? id,
    String? name,
    String? type,
    String? listen,
    int? port,
    String? serverID,
    String? serverName,
    String? groupID,
    String? groupName,
    bool? active,
    int? connections,
    int? upload,
    int? download,
    bool? autoConnect,
  }) =>
      Egress(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        listen: listen ?? this.listen,
        port: port ?? this.port,
        serverID: serverID ?? this.serverID,
        serverName: serverName ?? this.serverName,
        groupID: groupID ?? this.groupID,
        groupName: groupName ?? this.groupName,
        active: active ?? this.active,
        connections: connections ?? this.connections,
        upload: upload ?? this.upload,
        download: download ?? this.download,
        autoConnect: autoConnect ?? this.autoConnect,
      );
}
