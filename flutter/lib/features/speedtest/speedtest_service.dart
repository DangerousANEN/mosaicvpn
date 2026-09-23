import 'dart:async';
import '../../core/platform/app_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import 'speedtest_models.dart';
import 'speedtest_probe.dart';

/// Provider for SpeedTestService.
final speedTestServiceProvider = Provider<SpeedTestService>((ref) {
  final api = ref.watch(daemonApiProvider);
  final probe = HttpSpeedTestProbe();
  final service = SpeedTestService(
    probe: probe,
    prepare: () async {
      if (!AppPlatform.isAndroid) {
        final prefs = await api.getPrefs();
        probe.proxyAddr = prefs.httpAddr;
        if (probe.proxyAddr?.isEmpty != false) {
          throw StateError('HTTP proxy endpoint is unavailable');
        }
      }
    },
    onGetActiveServerName: () async {
      try {
        final status = await api.getStatus();
        return status.server?.name ?? 'Current Connection';
      } catch (_) {
        return 'Current Connection';
      }
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Service orchestrating speed test execution with real measurement stages.
class SpeedTestService {
  final SpeedTestProbe _probe;
  final Future<void> Function()? prepare;
  bool _executing = false;
  final Future<String> Function()? _onGetActiveServerName;

  final _progressController = StreamController<SpeedTestProgress>.broadcast(sync: true);
  SpeedTestProgress _currentProgress = const SpeedTestProgress();
  bool _cancelled = false;

  SpeedTestService({
    SpeedTestProbe? probe,
    this.prepare,
    Future<String> Function()? onGetActiveServerName,
  })  : _probe = probe ?? HttpSpeedTestProbe(),
        _onGetActiveServerName = onGetActiveServerName;

  Stream<SpeedTestProgress> get progressStream => _progressController.stream;
  SpeedTestProgress get currentProgress => _currentProgress;
  bool get isRunning => _currentProgress.isRunning;

  void _emit(SpeedTestProgress progress) {
    if (_cancelled && progress.stage != SpeedTestStage.cancelled) return;
    _currentProgress = progress;
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }

  void cancel() {
    _cancelled = true;
    _probe.cancel();
    _emit(_currentProgress.copyWith(
      stage: SpeedTestStage.cancelled,
      statusMessage: 'Speed test cancelled',
    ));
  }

  /// Run speed test for the current active connection.
  Future<SpeedTestResult> runTest({
    String target = 'current',
    String? serverName,
    SpeedProbePolicy? policy,
  }) async {
    if (_executing) throw StateError('Speed test is already running');
    _executing = true;
    _cancelled = false;
    final totalWatch = Stopwatch()..start();

    String resolvedServerName = serverName ?? '';

    _emit(SpeedTestProgress(
      stage: SpeedTestStage.ping,
      statusMessage: 'Measuring latency & jitter…',
      stageProgress: 0.0,
      totalProgress: 0.05,
    ));

    try {
      await prepare?.call();
      if (resolvedServerName.isEmpty && _onGetActiveServerName != null) {
        resolvedServerName = await _onGetActiveServerName();
      }
      if (_cancelled) throw StateError('Cancelled');
      // -------------------------------------------------------------
      // STAGE 1: Latency & Jitter Probes
      // -------------------------------------------------------------
      final samples = <int>[];
      await _probe.probePing(
        count: 4,
        onSample: (sampleMs, index, total) {
          samples.add(sampleMs);
          final runningMedian = _calculateMedian(samples);
          final runningJitter = _calculateJitter(samples);
          final stageProgress = (index + 1) / total;
          final totalProgress = 0.05 + (stageProgress * 0.20); // 0.05 -> 0.25

          _emit(_currentProgress.copyWith(
            stage: SpeedTestStage.ping,
            currentPingMs: sampleMs,
            latencyMs: runningMedian,
            jitterMs: runningJitter,
            pingSamples: List.unmodifiable(samples),
            stageProgress: stageProgress,
            totalProgress: totalProgress,
            statusMessage: 'Ping: ${sampleMs}ms (${index + 1}/$total)',
          ));
        },
      );

      if (_cancelled) {
        return _buildResult(
          target: target,
          serverName: resolvedServerName,
          error: 'Cancelled',
          duration: totalWatch.elapsedMilliseconds / 1000.0,
        );
      }

      final finalLatency = _calculateMedian(samples);
      final finalJitter = _calculateJitter(samples);

      // -------------------------------------------------------------
      // STAGE 2: Download Bandwidth Probe
      // -------------------------------------------------------------
      _emit(_currentProgress.copyWith(
        stage: SpeedTestStage.download,
        statusMessage: 'Measuring download speed…',
        stageProgress: 0.0,
        totalProgress: 0.25,
        currentBps: 0,
        peakBps: 0,
        transferredBytes: 0,
        targetBytes: policy?.sampleBytes ?? 5 * 1024 * 1024,
      ));

      int finalDownloadBps = 0;
      int peakDownloadBps = 0;

      await for (final chunk in _probe.probeDownload(
        sampleBytes: policy?.sampleBytes ?? 5 * 1024 * 1024,
        maxDuration: Duration(seconds: policy?.timeoutSeconds ?? 4),
        downloadUrls: policy?.downloadUrls ?? const [],
      )) {
        if (_cancelled) break;
        if (chunk.currentBps > peakDownloadBps) {
          peakDownloadBps = chunk.currentBps;
        }
        finalDownloadBps = chunk.currentBps;

        final stageProg = chunk.progress;
        final totalProg = 0.25 + (stageProg * 0.40); // 0.25 -> 0.65

        _emit(_currentProgress.copyWith(
          stage: SpeedTestStage.download,
          currentBps: chunk.currentBps,
          peakBps: peakDownloadBps,
          transferredBytes: chunk.bytesTransferred,
          targetBytes: chunk.targetBytes,
          downloadBps: chunk.currentBps,
          stageProgress: stageProg,
          totalProgress: totalProg,
          statusMessage: 'Testing download…',
        ));
      }

      if (_cancelled) {
        return _buildResult(
          target: target,
          serverName: resolvedServerName,
          latency: finalLatency,
          jitter: finalJitter,
          downloadBps: finalDownloadBps,
          error: 'Cancelled',
          duration: totalWatch.elapsedMilliseconds / 1000.0,
        );
      }

      // -------------------------------------------------------------
      // STAGE 3: Upload Bandwidth Probe
      // -------------------------------------------------------------
      _emit(_currentProgress.copyWith(
        stage: SpeedTestStage.upload,
        statusMessage: 'Measuring upload speed…',
        stageProgress: 0.0,
        totalProgress: 0.65,
        currentBps: 0,
        peakBps: 0,
        transferredBytes: 0,
        targetBytes: policy?.sampleBytes ?? 2 * 1024 * 1024,
      ));

      int finalUploadBps = 0;
      int peakUploadBps = 0;

      await for (final chunk in _probe.probeUpload(
        sampleBytes: (policy?.sampleBytes != null)
            ? (policy!.sampleBytes ~/ 2)
            : 2 * 1024 * 1024,
        maxDuration: Duration(seconds: policy?.timeoutSeconds ?? 3),
        uploadUrl: policy?.uploadUrl ?? '',
      )) {
        if (_cancelled) break;
        if (chunk.currentBps > peakUploadBps) {
          peakUploadBps = chunk.currentBps;
        }
        finalUploadBps = chunk.currentBps;

        final stageProg = chunk.progress;
        final totalProg = 0.65 + (stageProg * 0.35); // 0.65 -> 1.00

        _emit(_currentProgress.copyWith(
          stage: SpeedTestStage.upload,
          currentBps: chunk.currentBps,
          peakBps: peakUploadBps,
          transferredBytes: chunk.bytesTransferred,
          targetBytes: chunk.targetBytes,
          uploadBps: chunk.currentBps,
          stageProgress: stageProg,
          totalProgress: totalProg,
          statusMessage: 'Testing upload…',
        ));
      }

      if (_cancelled) {
        return _buildResult(
          target: target,
          serverName: resolvedServerName,
          latency: finalLatency,
          jitter: finalJitter,
          downloadBps: finalDownloadBps,
          uploadBps: finalUploadBps,
          error: 'Cancelled',
          duration: totalWatch.elapsedMilliseconds / 1000.0,
        );
      }

      // -------------------------------------------------------------
      // STAGE 4: Completed
      // -------------------------------------------------------------
      final durationSec = totalWatch.elapsedMilliseconds / 1000.0;
      final result = SpeedTestResult(
        target: target,
        serverName: resolvedServerName,
        downloadBps: finalDownloadBps,
        uploadBps: finalUploadBps,
        latencyMS: finalLatency,
        jitterMS: finalJitter,
        durationSeconds: durationSec,
        error: '',
      );

      _emit(_currentProgress.copyWith(
        stage: SpeedTestStage.completed,
        stageProgress: 1.0,
        totalProgress: 1.0,
        currentBps: 0,
        statusMessage: 'Speed test completed',
        result: result,
      ));

      return result;
    } catch (e) {
      final errorMsg = _cancelled ? 'Cancelled' : e.toString();
      final durationSec = totalWatch.elapsedMilliseconds / 1000.0;
      final result = SpeedTestResult(
        target: target,
        serverName: resolvedServerName,
        downloadBps: _currentProgress.downloadBps ?? 0,
        uploadBps: _currentProgress.uploadBps ?? 0,
        latencyMS: _currentProgress.latencyMs ?? 0,
        jitterMS: _currentProgress.jitterMs ?? 0,
        durationSeconds: durationSec,
        error: errorMsg,
      );

      _emit(_currentProgress.copyWith(
        stage: _cancelled ? SpeedTestStage.cancelled : SpeedTestStage.failed,
        statusMessage: 'Speed test failed',
        error: errorMsg,
        result: result,
      ));

      return result;
    } finally {
      _executing = false;
    }
  }

  static int _calculateMedian(List<int> samples) {
    if (samples.isEmpty) return 0;
    final sorted = List<int>.from(samples)..sort();
    return sorted[sorted.length ~/ 2];
  }

  static int _calculateJitter(List<int> samples) {
    if (samples.length <= 1) return 0;
    final sorted = List<int>.from(samples)..sort();
    return (sorted.last - sorted.first).abs();
  }

  SpeedTestResult _buildResult({
    required String target,
    required String serverName,
    int latency = 0,
    int jitter = 0,
    int downloadBps = 0,
    int uploadBps = 0,
    String error = '',
    double duration = 0.0,
  }) {
    return SpeedTestResult(
      target: target,
      serverName: serverName,
      downloadBps: downloadBps,
      uploadBps: uploadBps,
      latencyMS: latency,
      jitterMS: jitter,
      durationSeconds: duration,
      error: error,
    );
  }

  void dispose() {
    _cancelled = true;
    _probe.cancel();
    _progressController.close();
  }
}
