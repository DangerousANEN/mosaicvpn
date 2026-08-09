import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/dashboard/dashboard_screen.dart';

/// T-08: a station's name used to collapse to a handful of characters once a
/// latency measurement arrived. The badge appeared only after a ping, so the
/// row's trailing group grew and stole width from the title.
///
/// These tests pin the fix: the latency slot is reserved up front, so measuring
/// a server must not change how much room its name gets.
const _longName = 'Frankfurt Premium Gateway 01';

Widget _harness(List<Server> servers) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
        serversProvider.overrideWith((ref) async => servers),
      ],
      // Scaffold, not a bare DashboardScreen: the station list uses ListTile,
      // which asserts on a missing Material ancestor.
      child: const MaterialApp(
        home: Scaffold(body: DashboardScreen()),
      ),
    );

Server _server({required int lastTestMS}) => Server(
      id: 'srv-1',
      name: _longName,
      address: '10.0.0.1',
      port: 443,
      country: 'DE',
      lastTestMS: lastTestMS,
    );

/// Station rows live inside a per-subscription ExpansionTile that starts
/// collapsed, so a test has to open it before any row exists in the tree.
Future<void> _expandGroups(WidgetTester tester) async {
  final groups = find.byType(ExpansionTile);
  expect(groups, findsWidgets, reason: 'no station groups rendered');
  await tester.tap(groups.first);
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

/// Renders the dashboard at a desktop size and returns the rendered width of
/// the station's name.
Future<double> _nameWidth(WidgetTester tester, {required int lastTestMS}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_harness([_server(lastTestMS: lastTestMS)]));
  await tester.pumpAndSettle(const Duration(seconds: 2));
  await _expandGroups(tester);

  final finder = find.text(_longName);
  expect(finder, findsOneWidget,
      reason: 'station row did not render (lastTestMS=$lastTestMS)');
  return tester.getSize(finder).width;
}

void main() {
  testWidgets('measuring latency does not shrink the server name',
      (tester) async {
    final unmeasured = await _nameWidth(tester, lastTestMS: 0);
    final measured = await _nameWidth(tester, lastTestMS: 87);

    expect(measured, closeTo(unmeasured, 1.0),
        reason: 'name was $unmeasured wide before the ping and $measured after; '
            'the latency slot must be reserved so the title keeps its width');
  });

  testWidgets('long server names are not clipped to a few characters',
      (tester) async {
    final width = await _nameWidth(tester, lastTestMS: 87);

    // The bug rendered roughly five glyphs. At 12px, twenty characters need
    // well over 100 logical pixels.
    expect(width, greaterThan(100.0),
        reason: 'name rendered only $width wide, which is the clipped-title bug');
  });

  testWidgets('latency badge is shown once a measurement exists',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness([_server(lastTestMS: 87)]));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _expandGroups(tester);

    // Reserving the slot must not mean the number stops being displayed.
    expect(find.text('87ms'), findsOneWidget);
  });
}
