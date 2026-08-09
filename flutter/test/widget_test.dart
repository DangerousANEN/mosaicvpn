import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/app/app_shell.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';

/// Smoke tests for the shell that owns navigation.
///
/// The daemon API is mocked and vpnStatusProvider is replaced with a single
/// value: the real provider polls on a periodic Timer that outlives the widget
/// tree and trips the binding's pending-timer assertion on teardown, while an
/// unmocked HttpClient makes the suite emit network warnings.
Widget _harness() => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
      ],
      child: const MaterialApp(home: AppShell()),
    );

/// Sets a device-sized surface and lets the tree build.
///
/// The default 800x600 test window is not a size the app targets, and laying
/// the shell out there overflows the dashboard, so every test picks a real
/// device size.
///
/// pumpAndSettle is required rather than fixed pumps: MockDaemonApi resolves
/// through delayed futures, and leaving them outstanding trips the binding's
/// pending-timer assertion on teardown.
Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

void main() {
  testWidgets('phone shell exposes exactly five tabs', (tester) async {
    await _pumpAt(tester, const Size(390, 844));

    // Five is the T-05 contract: the previous fifteen did not fit a phone.
    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bar.items.length, 5);

    for (final label in [
      'Dashboard',
      'Groups',
      'Subscriptions',
      'Billing',
      'More'
    ]) {
      expect(find.text(label), findsWidgets, reason: 'missing tab: $label');
    }
  });

  testWidgets('phone shell lays out without overflow on a small screen',
      (tester) async {
    await _pumpAt(tester, const Size(360, 640));

    expect(tester.takeException(), isNull,
        reason: '360x640 is a real device size and must lay out clean');
  });
}
