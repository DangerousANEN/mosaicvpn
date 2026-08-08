/// Test result for server latency / URL / IP tests.
/// Matches Go: proto.TestResult
class TestResult {
  final String serverID;
  final String serverName;
  final int latencyMS; // <0 = failed
  final String error;
  final DateTime testedAt;

  TestResult({
    this.serverID = '',
    this.serverName = '',
    this.latencyMS = 0,
    this.error = '',
    DateTime? testedAt,
  }) : testedAt = testedAt ?? DateTime.now();

  factory TestResult.fromJson(Map<String, dynamic> j) => TestResult(
        serverID: j['server_id'] ?? '',
        serverName: j['server_name'] ?? '',
        latencyMS: j['latency_ms'] ?? 0,
        error: j['error'] ?? '',
        testedAt:
            j['tested_at'] != null ? DateTime.tryParse(j['tested_at']) : null,
      );

  bool get failed => latencyMS < 0 || error.isNotEmpty;
}

/// Speed test result.
/// Matches Go: proto.SpeedTestResult
class SpeedTestResult {
  final String target; // "current" | "group" | server_id
  final String serverName;
  final int downloadBps; // bytes per second
  final int uploadBps;
  final int latencyMS;
  final int jitterMS;
  final double durationSeconds;
  final String error;

  SpeedTestResult({
    this.target = '',
    this.serverName = '',
    this.downloadBps = 0,
    this.uploadBps = 0,
    this.latencyMS = 0,
    this.jitterMS = 0,
    this.durationSeconds = 0,
    this.error = '',
  });

  factory SpeedTestResult.fromJson(Map<String, dynamic> j) => SpeedTestResult(
        target: j['target'] ?? '',
        serverName: j['server_name'] ?? '',
        downloadBps: j['download_bps'] ?? 0,
        uploadBps: j['upload_bps'] ?? 0,
        latencyMS: j['latency_ms'] ?? 0,
        jitterMS: j['jitter_ms'] ?? 0,
        durationSeconds: (j['duration_seconds'] ?? 0).toDouble(),
        error: j['error'] ?? '',
      );
}
