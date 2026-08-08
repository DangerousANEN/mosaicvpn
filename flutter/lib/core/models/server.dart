import 'dart:convert';

import 'protocol.dart';
import 'server_group.dart';

/// VPN server endpoint.
/// Matches Go: proto.Server
class Server {
  final String id;
  final String name;
  final Protocol protocol;
  final String address;
  final int port;
  final String city;
  final String country;
  final double lat;
  final double lon;
  final String tag;
  final String subscriptionID;
  final String groupId; // dedicated group id, '' → Ungrouped
  final bool isVirtualGroup;
  final String category; // 'smart', 'whitelist', 'raw'
  final String groupTag;
  final String outboundTag;
  final int lastTestMS; // <0 = failed, 0 = untested
  final String lastTestError;
  final int? upSpeed; // bps
  final int? downSpeed; // bps

  Server({
    required this.id,
    this.name = '',
    this.protocol = Protocol.custom,
    this.address = '',
    this.port = 0,
    this.city = '',
    this.country = '',
    this.lat = 0,
    this.lon = 0,
    this.tag = '',
    this.subscriptionID = '',
    this.groupId = '',
    this.isVirtualGroup = false,
    this.category = '',
    this.groupTag = '',
    this.outboundTag = '',
    this.lastTestMS = 0,
    this.lastTestError = '',
    this.upSpeed,
    this.downSpeed,
  });

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        protocol: Protocol.fromString(j['protocol'] ?? ''),
        address: j['address'] ?? '',
        port: j['port'] ?? 0,
        city: j['city'] ?? '',
        country: j['country'] ?? '',
        lat: (j['lat'] ?? 0).toDouble(),
        lon: (j['lon'] ?? 0).toDouble(),
        tag: j['tag'] ?? '',
        subscriptionID: j['subscription_id'] ?? '',
        groupId: j['group_id'] ?? '',
        isVirtualGroup: j['is_virtual_group'] ?? false,
        category: j['category'] ?? '',
        groupTag: j['group_tag'] ?? '',
        outboundTag: j['outbound_tag'] ?? '',
        lastTestMS: j['last_test_ms'] ?? 0,
        lastTestError: j['last_test_error'] ?? '',
        upSpeed: j['up_speed'],
        downSpeed: j['down_speed'],
      );

  /// Serialise to JSON — the inverse of [fromJson]. Used by the backup
  /// pipeline (Phase 2.5) to persist servers into a portable JSON bundle.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.value,
        'address': address,
        'port': port,
        'city': city,
        'country': country,
        'lat': lat,
        'lon': lon,
        'tag': tag,
        'subscription_id': subscriptionID,
        'group_id': groupId,
        'is_virtual_group': isVirtualGroup,
        'category': category,
        'group_tag': groupTag,
        'outbound_tag': outboundTag,
        'last_test_ms': lastTestMS,
        'last_test_error': lastTestError,
        'up_speed': upSpeed,
        'down_speed': downSpeed,
      };

  /// Copy with overrides — used for moves between groups and in-place edits.
  Server copyWith({
    String? id,
    String? name,
    Protocol? protocol,
    String? address,
    int? port,
    String? city,
    String? country,
    double? lat,
    double? lon,
    String? tag,
    String? subscriptionID,
    String? groupId,
    int? lastTestMS,
    String? lastTestError,
    int? upSpeed,
    int? downSpeed,
  }) =>
      Server(
        id: id ?? this.id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        address: address ?? this.address,
        port: port ?? this.port,
        city: city ?? this.city,
        country: country ?? this.country,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        tag: tag ?? this.tag,
        subscriptionID: subscriptionID ?? this.subscriptionID,
        groupId: groupId ?? this.groupId,
        lastTestMS: lastTestMS ?? this.lastTestMS,
        lastTestError: lastTestError ?? this.lastTestError,
        upSpeed: upSpeed ?? this.upSpeed,
        downSpeed: downSpeed ?? this.downSpeed,
      );

  /// Parse a URI share-link into a [Server].
  /// Supports: vless, vmess (base64 JSON), trojan, ss (plain & base64),
  /// ssr, ss2022, shadowtls, anytls, hysteria2, tuic, juicity, naive+https,
  /// mieru, wireguard, socks, http.
  /// Returns `null` if the scheme is unknown or required fields are missing.
  static Server? fromUri(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.contains('://')) return null;

    // vmess://base64(json)
    final vm = RegExp(r'^vmess://([A-Za-z0-9+/=_\-]+)$').firstMatch(trimmed);
    if (vm != null) {
      try {
        final b = vm.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
        final padded = b + '=' * ((4 - b.length % 4) % 4);
        final json = jsonDecode(utf8.decode(base64.decode(padded)))
            as Map<String, dynamic>;
        return Server(
          id: '',
          name: (json['ps'] ?? json['add'] ?? 'vmess').toString(),
          protocol: Protocol.vmess,
          address: (json['add'] ?? '').toString(),
          port: int.tryParse((json['port'] ?? '0').toString()) ?? 0,
          groupId: ServerGroup.ungroupedId,
        );
      } catch (_) {
        return null;
      }
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty && uri.userInfo.isEmpty) {
      // maybe a base64-payload ss:// — try decoding
      final m = RegExp(r'^ss://([A-Za-z0-9+/=_\-]+)').firstMatch(trimmed);
      if (m != null) {
        try {
          final b = m.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
          final padded = b + '=' * ((4 - b.length % 4) % 4);
          final decoded = utf8.decode(base64.decode(padded));
          // decoded is method:password@host:port
          final atIdx = decoded.lastIndexOf('@');
          if (atIdx < 0) return null;
          // methodPass = "method:password" (shadowsocks auth)
          // hostPort = "host:port"
          final methodPass = decoded.substring(0, atIdx);
          final hostPort = decoded.substring(atIdx + 1);
          final colon = hostPort.indexOf(':');
          if (colon < 0) return null;
          // methodPass = "method:password" (shadowsocks auth)
          final ssMethod = methodPass.split(':').first;
          final host = hostPort.substring(0, colon);
          final portStr =
              hostPort.substring(colon + 1).split(RegExp(r'[/#?]'))[0];
          return Server(
            id: '',
            name: host,
            protocol: Protocol.shadowsocks,
            address: host,
            port: int.tryParse(portStr) ?? 0,
            tag: ssMethod,
            groupId: ServerGroup.ungroupedId,
          );
        } catch (_) {
          return null;
        }
      }
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    final proto = _schemeToProtocol(scheme);
    if (proto == null) return null;

    final host = uri.host;
    final port = uri.port > 0 ? uri.port : _defaultPort(scheme);
    if (host.isEmpty && uri.userInfo.isEmpty) return null;
    final display = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${proto.displayName} $host';

    return Server(
      id: '',
      name: display,
      protocol: proto,
      address: host,
      port: port,
      groupId: ServerGroup.ungroupedId,
    );
  }

  static Protocol? _schemeToProtocol(String s) {
    switch (s) {
      case 'vless':
        return Protocol.vless;
      case 'vmess':
        return Protocol.vmess;
      case 'trojan':
        return Protocol.trojan;
      case 'ss':
        return Protocol.shadowsocks;
      case 'ssr':
        return Protocol.shadowsocksR;
      case 'ss2022':
        return Protocol.shadowsocks2022;
      case 'shadowtls':
        return Protocol.shadowTLS;
      case 'anytls':
        return Protocol.anyTLS;
      case 'hysteria2':
      case 'hy2':
        return Protocol.hysteria2;
      case 'tuic':
        return Protocol.tuic;
      case 'juicity':
        return Protocol.juicity;
      case 'naive+https':
        return Protocol.naive;
      case 'mieru':
        return Protocol.mieru;
      case 'wireguard':
        return Protocol.wireguard;
      case 'amneziawg':
        return Protocol.amneziaWG;
      case 'http3':
        return Protocol.http3;
      case 'trusttunnel':
        return Protocol.trustTunnel;
      case 'socks':
        return Protocol.socks;
      case 'http':
        return Protocol.http;
      case 'ssh':
        return Protocol.ssh;
      default:
        return null;
    }
  }

  static int _defaultPort(String s) {
    switch (s) {
      case 'vless':
      case 'vmess':
      case 'trojan':
      case 'naive+https':
      case 'wireguard':
        return 443;
      case 'ss':
      case 'ssr':
        return 8388;
      case 'hysteria2':
      case 'hy2':
      case 'tuic':
      case 'juicity':
        return 443;
      case 'socks':
        return 1080;
      case 'http':
        return 8080;
      default:
        return 0;
    }
  }

  /// Raw URI share-link reconstructed from server fields (best-effort).
  String get rawUri {
    if (address.isEmpty) return '';
    final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
    final userInfo = subscriptionID.isNotEmpty ? '$subscriptionID@' : '';
    return '${protocol.uriScheme}://$userInfo$address:$port$frag';
  }

  String get location {
    final parts = <String>[];
    if (city.isNotEmpty) parts.add(city);
    if (country.isNotEmpty) parts.add(country);
    return parts.join(', ');
  }

  bool get hasGeoCoords => lat != 0 || lon != 0;
  bool get hasLatency => lastTestMS > 0;
  bool get latencyFailed => lastTestMS < 0;
  bool get isUngrouped => groupId.isEmpty || groupId == ServerGroup.ungroupedId;
}
