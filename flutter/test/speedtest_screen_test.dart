import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_gauge.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_models.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_probe.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_screen.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_service.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_stage_tracker.dart';

Widget _buildTestApp({
  required SpeedTestService service,
  MockDaemonApi? api,
}) {
  final mockApi = api ?? MockDaemonApi();
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(mockApi),
      speedTestServiceProvider.overrideWithValue(service),
      vpnStatusProvider.overrideWith((ref) => Stream.value(
            VpnStatus(
              state: 'connected',
              server: Server(id: 'berlin', name: 'Berlin-Node', address: 'localhost', port: 443, protocol: Protocol.vless),
              bytesIn: 1024,
              bytesOut: 2048,
            ),
          )),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SpeedTestScreen(service: service),
      ),
    ),
  );
}

void main() {
  group('SpeedTestScreen Widget & Animation Tests', () {
    testWidgets('renders initial idle state with target selector and start button',
        (tester) async {
      final mockProbe = MockSpeedTestProbe();
      final service = SpeedTestService(probe: mockProbe);

      await tester.pumpWidget(_buildTestApp(service: service));
      await tester.pump();

      expect(find.text('Speed Test'), findsOneWidget);
      expect(find.text('Real-time bandwidth and latency diagnostics'),
          findsOneWidget);
      expect(find.text('Current Connection'), findsOneWidget);
      expect(find.text('All Servers (Group Test)'), findsOneWidget);
      expect(find.text('Start Test'), findsOneWidget);

      // Gauge and tracker should be rendered even initially (no empty blank space)
      expect(find.byType(SpeedtestGauge), findsOneWidget);
      expect(find.byType(SpeedtestStageTracker), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.text('Ping'), findsOneWidget);
      expect(find.text('Download'), findsAtLeastNWidgets(1));
      expect(find.text('Upload'), findsAtLeastNWidgets(1));
    });

    testWidgets('shows live stage progression and measurements during test',
        (tester) async {
      final mockProbe = MockSpeedTestProbe(
        mockPingSamples: [25, 27, 26, 28],
        mockDownloadChunks: [
          const SpeedChunkProgress(
            bytesTransferred: 2500000,
            targetBytes: 5000000,
            currentBps: 25000000,
            progress: 0.5,
          ),
          const SpeedChunkProgress(
            bytesTransferred: 5000000,
            targetBytes: 5000000,
            currentBps: 50000000,
            progress: 1.0,
            isDone: true,
          ),
        ],
        mockUploadChunks: [
          const SpeedChunkProgress(
            bytesTransferred: 1000000,
            targetBytes: 2000000,
            currentBps: 20000000,
            progress: 0.5,
          ),
          const SpeedChunkProgress(
            bytesTransferred: 2000000,
            targetBytes: 2000000,
            currentBps: 30000000,
            progress: 1.0,
            isDone: true,
          ),
        ],
        tickDelay: const Duration(milliseconds: 60),
      );

      final service = SpeedTestService(
        probe: mockProbe,
        onGetActiveServerName: () async => 'Amsterdam-01',
      );

      await tester.pumpWidget(_buildTestApp(service: service));
      await tester.pump();

      // Tap Start Test
      await tester.tap(find.text('Start Test'));
      await tester.pump();

      // MEASURING indicator and Cancel button should be immediately visible
      expect(find.text('MEASURING'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Each fake timer schedules its successor after a pump.
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Ping: 25ms (1/4)'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(service.currentProgress.stage, SpeedTestStage.download);
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(service.currentProgress.stage, SpeedTestStage.upload);
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();

      // After completion:
      expect(find.text('Run Again'), findsOneWidget);
      expect(find.text('TEST COMPLETE'), findsOneWidget);
      expect(find.text('Test Details'), findsOneWidget);
      expect(find.text('Berlin-Node'), findsOneWidget);
    });

    testWidgets('cancelling test stops execution and updates UI cleanly',
        (tester) async {
      final mockProbe = MockSpeedTestProbe(
        mockPingSamples: [20, 22, 24, 26],
        mockDownloadChunks: List.generate(
          10,
          (i) => SpeedChunkProgress(
            bytesTransferred: (i + 1) * 500000,
            targetBytes: 5000000,
            currentBps: 20000000,
            progress: (i + 1) / 10,
          ),
        ),
        tickDelay: const Duration(milliseconds: 100),
      );

      final service = SpeedTestService(probe: mockProbe);

      await tester.pumpWidget(_buildTestApp(service: service));
      await tester.pump();

      await tester.tap(find.text('Start Test'));
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);

      // Click Cancel
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Start Test'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('cancelling group test with empty servers does not overwrite cancelled state on completion',
        (tester) async {
      final mockApi = _ControllableGroupSpeedApi();
      mockApi.groupCompleter = Completer<List<SpeedTestResult>>();
      final mockProbe = MockSpeedTestProbe();
      final service = SpeedTestService(probe: mockProbe);

      await tester.pumpWidget(_buildTestApp(service: service, api: mockApi));
      await tester.pump();

      // Switch to Group Test
      await tester.tap(find.text('All Servers (Group Test)'));
      await tester.pumpAndSettle();

      // Tap Start Test
      await tester.tap(find.text('Start Test'));
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);

      // Cancel the group test
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Start Test'), findsOneWidget);

      // In-flight group test completes after cancellation
      mockApi.groupCompleter!.complete([
        SpeedTestResult(
          target: 'all',
          serverName: 'Server 1',
          downloadBps: 10000000,
          uploadBps: 5000000,
          latencyMS: 20,
          jitterMS: 2,
          durationSeconds: 2.0,
        ),
      ]);
      await tester.pumpAndSettle();

      // Must STAY cancelled / not completed:
      // In group test, completed changes Start Test to "Run Again" and shows Fleet Speed Results.
      // Since it was cancelled, it must NOT show Run Again or Fleet Speed Results.
      expect(find.text('Run Again'), findsNothing);
      expect(find.text('Start Test'), findsOneWidget);
      expect(find.text('Fleet Speed Results (1)'), findsNothing);
      expect(find.text('No group results yet.'), findsOneWidget);
    });

    testWidgets('cancelling group test with server list does not overwrite cancelled state after loop break',
        (tester) async {
      final mockApi = _ControllableServersSpeedApi();
      mockApi.speedCompleter = Completer<SpeedTestResult>();
      final mockProbe = MockSpeedTestProbe();
      final service = SpeedTestService(probe: mockProbe);

      await tester.pumpWidget(_buildTestApp(service: service, api: mockApi));
      await tester.pump();

      await tester.tap(find.text('All Servers (Group Test)'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start Test'));
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);

      // Tap Cancel while server speedtest is in-flight
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Start Test'), findsOneWidget);

      // In-flight server completes
      mockApi.speedCompleter!.complete(SpeedTestResult(
        target: 's1',
        serverName: 'Server 1',
        downloadBps: 10000000,
        uploadBps: 5000000,
        latencyMS: 20,
        jitterMS: 2,
        durationSeconds: 2.0,
      ));
      await tester.pumpAndSettle();

      // Must STAY not-completed: Start Test must NOT have changed to Run Again
      expect(find.text('Run Again'), findsNothing);
      expect(find.text('Start Test'), findsOneWidget);
    });

    testWidgets('cancel followed by immediate restart does not have first test unset running state',
        (tester) async {
      final mockApi = _ControllableGroupSpeedApi();
      mockApi.groupCompleter = Completer<List<SpeedTestResult>>();
      final mockProbe = MockSpeedTestProbe();
      final service = SpeedTestService(probe: mockProbe);

      await tester.pumpWidget(_buildTestApp(service: service, api: mockApi));
      await tester.pump();

      await tester.tap(find.text('All Servers (Group Test)'));
      await tester.pumpAndSettle();

      // Start test 1
      await tester.tap(find.text('Start Test'));
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);

      // Cancel test 1
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(find.text('Start Test'), findsOneWidget);

      // Immediately start test 2 (groupCompleter 2)
      final completer1 = mockApi.groupCompleter!;
      mockApi.groupCompleter = Completer<List<SpeedTestResult>>();

      await tester.tap(find.text('Start Test'));
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);

      // Now complete test 1's old in-flight request
      completer1.complete([]);
      await tester.pump();

      // Test 2 must still be actively running (Cancel visible, not Start Test)
      expect(find.text('Cancel'), findsOneWidget,
          reason: 'Old test finishing must not unset running state of newly started test');
    });
  });
}

class _ControllableGroupSpeedApi extends MockDaemonApi {
  Completer<List<SpeedTestResult>>? groupCompleter;

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async => [];

  @override
  Future<List<SpeedTestResult>> testSpeedGroup(String groupLabel,
      {Duration? testFor}) async {
    if (groupCompleter != null) {
      return groupCompleter!.future;
    }
    return [
      SpeedTestResult(
        target: 'all',
        serverName: 'Server 1',
        downloadBps: 10000000,
        uploadBps: 5000000,
        latencyMS: 20,
        jitterMS: 2,
        durationSeconds: 2.0,
      ),
    ];
  }
}

class _ControllableServersSpeedApi extends MockDaemonApi {
  Completer<SpeedTestResult>? speedCompleter;

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async => [
        Server(
          id: 's1',
          name: 'Server 1',
          address: '1.1.1.1',
          port: 443,
          protocol: Protocol.vless,
        ),
        Server(
          id: 's2',
          name: 'Server 2',
          address: '1.1.1.2',
          port: 443,
          protocol: Protocol.vless,
        ),
      ];

  @override
  Future<SpeedTestResult> testSpeed(String serverID,
      {Duration? testFor}) async {
    if (speedCompleter != null) {
      return speedCompleter!.future;
    }
    return SpeedTestResult(
      target: serverID,
      serverName: serverID,
      downloadBps: 10000000,
      uploadBps: 5000000,
      latencyMS: 20,
      jitterMS: 2,
      durationSeconds: 2.0,
    );
  }
}
