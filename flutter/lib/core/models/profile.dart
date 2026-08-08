import 'dns_config.dart';

/// Profile — a named configuration bundle.
/// Matches Go: proto.Profile
class Profile {
  final String id;
  final String name;
  final String icon; // emoji or icon name
  final String color; // hex color
  final String serverID;
  final String subscriptionID;
  final String tunnelMode; // "tun" | "proxy"
  final bool killSwitch;
  final bool allowLAN;
  final DNSConfig dns;
  final List<String> ruleIDs;
  final bool autoConnect;
  final DateTime createdAt;
  final DateTime updatedAt;

  Profile({
    this.id = '',
    this.name = '',
    this.icon = '🛡',
    this.color = '#6366F1',
    this.serverID = '',
    this.subscriptionID = '',
    this.tunnelMode = 'tun',
    this.killSwitch = true,
    this.allowLAN = true,
    this.dns = const DNSConfig(),
    this.ruleIDs = const [],
    this.autoConnect = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt = updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        icon: j['icon'] ?? '🛡',
        color: j['color'] ?? '#6366F1',
        serverID: j['server_id'] ?? '',
        subscriptionID: j['subscription_id'] ?? '',
        tunnelMode: j['tunnel_mode'] ?? 'tun',
        killSwitch: j['kill_switch'] ?? true,
        allowLAN: j['allow_lan'] ?? true,
        dns:
            j['dns'] != null ? DNSConfig.fromJson(j['dns']) : const DNSConfig(),
        ruleIDs: (j['rule_ids'] as List?)?.cast<String>() ?? [],
        autoConnect: j['auto_connect'] ?? false,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] ?? '')
            : null,
        updatedAt: j['updated_at'] != null
            ? DateTime.tryParse(j['updated_at'] ?? '')
            : null,
      );
}
