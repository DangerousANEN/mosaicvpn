import '../../core/models/models.dart';

/// Stages of a speed test run.
enum SpeedTestStage {
  idle,
  ping,
  download,
  upload,
  completed,
  cancelled,
  failed,
}

/// Chunk progress event emitted during download and upload throughput probes.
class SpeedChunkProgress {
  final int bytesTransferred;
  final int targetBytes;
  final int currentBps;
  final double progress; // 0.0 to 1.0
  final bool isDone;

  const SpeedChunkProgress({
    required this.bytesTransferred,
    required this.targetBytes,
    required this.currentBps,
    required this.progress,
    this.isDone = false,
  });
}

/// Live progress snapshot for the speed test.
class SpeedTestProgress {
  final SpeedTestStage stage;
  final double stageProgress; // 0.0 to 1.0 for the current stage
  final double totalProgress; // 0.0 to 1.0 overall
  final int? currentPingMs;
  final int? latencyMs; // median latency
  final int? jitterMs;
  final List<int> pingSamples;
  final int currentBps;
  final int peakBps;
  final int transferredBytes;
  final int targetBytes;
  final int? downloadBps;
  final int? uploadBps;
  final String statusMessage;
  final SpeedTestResult? result;
  final String? error;

  const SpeedTestProgress({
    this.stage = SpeedTestStage.idle,
    this.stageProgress = 0.0,
    this.totalProgress = 0.0,
    this.currentPingMs,
    this.latencyMs,
    this.jitterMs,
    this.pingSamples = const [],
    this.currentBps = 0,
    this.peakBps = 0,
    this.transferredBytes = 0,
    this.targetBytes = 0,
    this.downloadBps,
    this.uploadBps,
    this.statusMessage = '',
    this.result,
    this.error,
  });

  bool get isRunning =>
      stage == SpeedTestStage.ping ||
      stage == SpeedTestStage.download ||
      stage == SpeedTestStage.upload;

  bool get isCompleted => stage == SpeedTestStage.completed;
  bool get isFailed => stage == SpeedTestStage.failed;
  bool get isCancelled => stage == SpeedTestStage.cancelled;

  SpeedTestProgress copyWith({
    SpeedTestStage? stage,
    double? stageProgress,
    double? totalProgress,
    int? currentPingMs,
    int? latencyMs,
    int? jitterMs,
    List<int>? pingSamples,
    int? currentBps,
    int? peakBps,
    int? transferredBytes,
    int? targetBytes,
    int? downloadBps,
    int? uploadBps,
    String? statusMessage,
    SpeedTestResult? result,
    String? error,
  }) {
    return SpeedTestProgress(
      stage: stage ?? this.stage,
      stageProgress: stageProgress ?? this.stageProgress,
      totalProgress: totalProgress ?? this.totalProgress,
      currentPingMs: currentPingMs ?? this.currentPingMs,
      latencyMs: latencyMs ?? this.latencyMs,
      jitterMs: jitterMs ?? this.jitterMs,
      pingSamples: pingSamples ?? this.pingSamples,
      currentBps: currentBps ?? this.currentBps,
      peakBps: peakBps ?? this.peakBps,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      targetBytes: targetBytes ?? this.targetBytes,
      downloadBps: downloadBps ?? this.downloadBps,
      uploadBps: uploadBps ?? this.uploadBps,
      statusMessage: statusMessage ?? this.statusMessage,
      result: result ?? this.result,
      error: error ?? this.error,
    );
  }
}
