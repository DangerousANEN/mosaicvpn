import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/dashboard/dashboard_screen.dart';

/// The desktop dashboard is a three-column Row. Each column shrink-wraps, so
/// content that grows past the viewport clips silently instead of scrolling.
Widget _harness(VpnStatus status) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(status)),
        serversProvider.overrideWith((ref) async => <Server>[]),
        mosaicManifestProvider.overrideWith((ref) async => ProviderManifest(
              providerName: 'MosaicVPN',
              groups: [ManifestGroup(id: 'test-group', title: 'Test group')],
            )),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        home: Scaffold(body: DashboardScreen()),
      ),
    );

Future<void> _pumpDesktop(WidgetTester tester, VpnStatus status) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_harness(status));
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

void main() {
  testWidgets('desktop dashboard lays out without overflow', (tester) async {
    // The longest footer-note wording: TUN + armed kill switch + LAN bypass.
    await _pumpDesktop(
      tester,
      VpnStatus(
        tunnelMode: 'tun',
        killSwitch: true,
        allowLAN: true,
      ),
    );

    expect(tester.takeException(), isNull,
        reason:
            '1440x900 is the reference desktop size and must lay out clean');
  });
}
