@Tags(['visual'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/account/account_screen.dart';
import 'package:mosaic_vpn/features/more/more_screen.dart';

Future<void> _pumpMobile(WidgetTester tester, Widget page, {bool frozen = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final mock = MockDaemonApi();
  await tester.runAsync(() => mock.redeemLinkCode(MockDaemonApi.mockValidLinkCode));
  if (frozen) await tester.runAsync(mock.freezeAccount);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(mock),
      vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
    ],
    child: MaterialApp(home: page),
  ));
  // These pages have mock-delayed loading states. A fixed pump avoids waiting
  // for any decorative animation that may be introduced later.
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  testWidgets('mobile account active', (tester) async {
    await _pumpMobile(tester, const AccountScreen());
    await expectLater(find.byType(AccountScreen), matchesGoldenFile('goldens/mobile_account_active.png'));
  });

  testWidgets('mobile account paused', (tester) async {
    await _pumpMobile(tester, const AccountScreen(), frozen: true);
    await expectLater(find.byType(AccountScreen), matchesGoldenFile('goldens/mobile_account_paused.png'));
  });

  testWidgets('mobile advanced tools', (tester) async {
    await _pumpMobile(tester, const MoreScreen());
    await expectLater(find.byType(MoreScreen), matchesGoldenFile('goldens/mobile_advanced_tools.png'));
  });
}
