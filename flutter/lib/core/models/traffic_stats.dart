/// Traffic statistics from the daemon.
/// Matches Go: proto.TrafficStats
class TrafficStats {
  final int totalUpload;
  final int totalDownload;
  final int uploadSpeed; // bytes per second
  final int downloadSpeed; // bytes per second
  final int activeConnections;
  final Duration uptime;
  final DateTime since;

  TrafficStats({
    this.totalUpload = 0,
    this.totalDownload = 0,
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.activeConnections = 0,
    this.uptime = Duration.zero,
    DateTime? since,
  }) : since = since ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory TrafficStats.fromJson(Map<String, dynamic> j) => TrafficStats(
        totalUpload: j['total_upload'] ?? 0,
        totalDownload: j['total_download'] ?? 0,
        uploadSpeed: j['upload_speed'] ?? 0,
        downloadSpeed: j['download_speed'] ?? 0,
        activeConnections: j['active_connections'] ?? 0,
        uptime: Duration(seconds: j['uptime_seconds'] ?? 0),
        since: j['since'] != null ? DateTime.tryParse(j['since']) : null,
      );
}
