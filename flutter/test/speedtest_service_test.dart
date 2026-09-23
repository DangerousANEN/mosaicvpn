import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_models.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_probe.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_service.dart';

void main() {
  group('SpeedTestService & Probes - Real Stages & Live Measurements', () {
    test('transitions through real stages in order and calculates real metrics',
        () async {
      final mockProbe = MockSpeedTestProbe(
        mockPingSamples: [20, 30, 25, 45],
        mockDownloadChunks: [
          const SpeedChunkProgress(
            bytesTransferred: 1000000,
            targetBytes: 5000000,
            currentBps: 20000000, // 20 Mbps
            progress: 0.2,
          ),
          const SpeedChunkProgress(
            bytesTransferred: 5000000,
            targetBytes: 5000000,
            currentBps: 40000000, // 40 Mbps
            progress: 1.0,
            isDone: true,
          ),
        ],
        mockUploadChunks: [
          const SpeedChunkProgress(
            bytesTransferred: 1000000,
            targetBytes: 2000000,
            currentBps: 15000000, // 15 Mbps
            progress: 0.5,
          ),
          const SpeedChunkProgress(
            bytesTransferred: 2000000,
            targetBytes: 2000000,
            currentBps: 25000000, // 25 Mbps
            progress: 1.0,
            isDone: true,
          ),
        ],
        tickDelay: Duration.zero,
      );

      final service = SpeedTestService(
        probe: mockProbe,
        onGetActiveServerName: () async => 'Frankfurt-01',
      );

      final recordedStages = <SpeedTestStage>[];
      final recordedPingSamples = <int>[];
      final recordedDownloadBps = <int>[];
      final recordedUploadBps = <int>[];

      service.progressStream.listen((p) {
        if (recordedStages.isEmpty || recordedStages.last != p.stage) {
          recordedStages.add(p.stage);
        }
        if (p.stage == SpeedTestStage.ping && p.currentPingMs != null) {
          recordedPingSamples.add(p.currentPingMs!);
        }
        if (p.stage == SpeedTestStage.download && p.currentBps > 0) {
          recordedDownloadBps.add(p.currentBps);
        }
        if (p.stage == SpeedTestStage.upload && p.currentBps > 0) {
          recordedUploadBps.add(p.currentBps);
        }
      });

      final result = await service.runTest(target: 'current');

      // 1. Assert all 4 real stages occurred in exact order
      expect(recordedStages, [
        SpeedTestStage.ping,
        SpeedTestStage.download,
        SpeedTestStage.upload,
        SpeedTestStage.completed,
      ]);

      // 2. Assert ping samples match real measurements (no fake values)
      expect(recordedPingSamples, [20, 30, 25, 45]);

      // Sorted: [20, 25, 30, 45]. Median is 30 (index 4~/2 = 2)
      // Jitter is 45 - 20 = 25
      expect(result.latencyMS, 30);
      expect(result.jitterMS, 25);

      // 3. Assert live download throughput matches real stream chunks
      expect(recordedDownloadBps, containsAll([20000000, 40000000]));
      expect(result.downloadBps, 40000000);

      // 4. Assert live upload throughput matches real stream chunks
      expect(recordedUploadBps, containsAll([15000000, 25000000]));
      expect(result.uploadBps, 25000000);

      // 5. Assert metadata
      expect(result.serverName, 'Frankfurt-01');
      expect(result.target, 'current');
      expect(result.error, isEmpty);
      expect(result.durationSeconds, greaterThanOrEqualTo(0));

      service.dispose();
    });

    test('cleanly aborts and records cancellation when cancel() is triggered',
        () async {
      final mockProbe = MockSpeedTestProbe(
        mockPingSamples: [15, 18, 16, 20],
        mockDownloadChunks: List.generate(
          10,
          (i) => SpeedChunkProgress(
            bytesTransferred: (i + 1) * 500000,
            targetBytes: 5000000,
            currentBps: 10000000 + i * 2000000,
            progress: (i + 1) / 10,
          ),
        ),
        tickDelay: const Duration(milliseconds: 25),
      );

      final service = SpeedTestService(
        probe: mockProbe,
        onGetActiveServerName: () async => 'Stockholm-02',
      );

      final testFuture = service.runTest(target: 'current');

      // Allow ping stage to begin, then cancel during test
      await Future.delayed(const Duration(milliseconds: 35));
      service.cancel();

      final result = await testFuture;

      expect(service.currentProgress.stage, SpeedTestStage.cancelled);
      expect(result.error, 'Cancelled');

      service.dispose();
    });

    test('handles probe failures gracefully with failure stage and error details',
        () async {
      final mockProbe = MockSpeedTestProbe(
        shouldFailPing: true,
      );

      final service = SpeedTestService(
        probe: mockProbe,
        onGetActiveServerName: () async => 'Test-Server',
      );

      final result = await service.runTest();

      expect(service.currentProgress.stage, SpeedTestStage.failed);
      expect(service.currentProgress.error, isNotNull);
      expect(result.error, contains('Simulated latency probe failure'));

      service.dispose();
    });
  });
}
