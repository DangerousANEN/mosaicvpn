import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/stats/stats_screen.dart';
import 'package:fl_chart/fl_chart.dart';

class SlowResetDaemonApi extends MockDaemonApi {
  Completer<void>? resetCompleter;
  int resetCallCount = 0;

  @override
  Future<void> resetStats() async {
    resetCallCount++;
    if (resetCompleter != null) {
      await resetCompleter!.future;
    }
  }

  @override
  Future<TrafficStats> getStats() async {
    return TrafficStats(
      uploadSpeed: 1000,
      downloadSpeed: 2000,
      totalUpload: 10000,
      totalDownload: 20000,
      since: DateTime.now(),
    );
  }
}

Widget _buildStatsApp(MockDaemonApi api) {
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(api),
      trafficStatsProvider.overrideWith((ref) => Stream.value(
            TrafficStats(
              uploadSpeed: 1000,
              downloadSpeed: 2000,
              totalUpload: 10000,
              totalDownload: 20000,
              since: DateTime.now(),
            ),
          )),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: StatsScreen(),
      ),
    ),
  );
}

void main() {
  testWidgets('repeated reset taps do not leak multiple timers or double-tick points',
      (tester) async {
    final api = SlowResetDaemonApi();
    api.resetCompleter = Completer<void>();

    await tester.pumpWidget(_buildStatsApp(api));
    await tester.pump();

    // Tap Reset twice rapidly while resetStats is delayed
    await tester.tap(find.text('Reset'));
    await tester.pump();
    await tester.tap(find.text('Reset'));
    await tester.pump();

    // Release the delayed reset
    api.resetCompleter!.complete();
    await tester.pump();
    await tester.pumpAndSettle();

    // Directly after reset, spots are cleared, so "Waiting for data…" is shown
    expect(find.text('Waiting for data…'), findsOneWidget);

    // Advance 1 second:
    // With a single timer ticking once per second, only 1 point is added,
    // so _upSpots.length is 1 (< 2), and "Waiting for data…" must STILL be shown!
    // But if repeated taps leaked a second timer, 2 points are added in 1 second,
    // and "Waiting for data…" is prematurely replaced by LineChart!
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Waiting for data…'), findsOneWidget,
        reason: 'After 1 second with a single timer, only 1 spot should be added, keeping "Waiting for data…" visible');
    expect(find.byType(LineChart), findsNothing);

    // Advance another second (total 2 seconds): exactly 2 spots, now LineChart appears
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LineChart), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData.first.spots.length, 2,
        reason: 'After 2 seconds with a single timer, exactly 2 spots should exist');
  });
}
