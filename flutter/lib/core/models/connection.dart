/// Connection is a live TCP/UDP flow.
/// Matches Go: proto.Connection
class Connection {
  final String id;
  final String network; // "tcp" | "udp"
  final String outbound; // outbound tag: "proxy", "direct", "block"
  final String domain;
  final String ip;
  final int port;
  final String sourceIP;
  final int sourcePort;
  final String process;
  final int upload;
  final int download;
  final DateTime? startAt;
  final String chain; // e.g. "proxy → vless"
  final String rule; // matching rule name

  Connection({
    required this.id,
    this.network = 'tcp',
    this.outbound = 'proxy',
    this.domain = '',
    this.ip = '',
    this.port = 0,
    this.sourceIP = '',
    this.sourcePort = 0,
    this.process = '',
    this.upload = 0,
    this.download = 0,
    this.startAt,
    this.chain = '',
    this.rule = '',
  });

  factory Connection.fromJson(Map<String, dynamic> j) => Connection(
        id: j['id'] ?? '',
        network: j['network'] ?? 'tcp',
        outbound: j['outbound'] ?? 'proxy',
        domain: j['domain'] ?? '',
        ip: j['ip'] ?? '',
        port: j['port'] ?? 0,
        sourceIP: j['source_ip'] ?? '',
        sourcePort: j['source_port'] ?? 0,
        process: j['process'] ?? '',
        upload: j['upload'] ?? 0,
        download: j['download'] ?? 0,
        startAt:
            j['start_at'] != null ? DateTime.tryParse(j['start_at']) : null,
        chain: j['chain'] ?? '',
        rule: j['rule'] ?? '',
      );

  String get host => domain.isNotEmpty ? domain : '$ip:$port';
  String get displayOutbound => outbound.toUpperCase();
  bool get isProxy => outbound == 'proxy';
  bool get isDirect => outbound == 'direct';
  bool get isBlocked => outbound == 'block';

  String get totalTraffic {
    final total = upload + download;
    if (total < 1024) return '$total B';
    if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(1)} KB';
    return '${(total / 1048576).toStringAsFixed(1)} MB';
  }
}
