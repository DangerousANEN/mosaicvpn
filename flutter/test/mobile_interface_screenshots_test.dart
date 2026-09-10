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

  // Semantic guard for the golden above. A golden alone cannot say WHY it
  // changed: when the tools list gains or loses an entry the pixel diff is the
  // only signal, and `--update-goldens` would silently bless a regression
  // (e.g. an accidentally deleted screen). These assertions pin the actual
  // menu contents, so a genuine removal fails loudly with a readable message.
  testWidgets('advanced tools list keeps every expected entry', (tester) async {
    await _pumpMobile(tester, const MoreScreen());

    // Added in v0.3.53; the golden was regenerated for it in v0.3.56.
    expect(find.textContaining('Egresses'), findsOneWidget,
        reason: 'Egresses (proxy ports) must stay reachable from More');

    // Titles come from AppStrings (localised), so pin the stable English
    // subtitles instead — they are literals in more_screen.dart.
    // NOTE: MoreScreen uses a lazy CustomScrollView, so entries below the fold
    // are not built at all on a 390x844 viewport — each one must be scrolled
    // into view before it can be found.
    const expectedSubtitles = <String>[
      'Clock, DNS, tunnel traffic, IPv6 leak and MTU',
      'Subscription-scoped profiles, traffic and payments',
      'Subscriptions, smart groups and your own nodes',
      'Named configurations and presets',
      'Routing rules and split tunneling',
      'Active connections and bandwidth',
      'Traffic statistics and graphs',
      'Latency and throughput benchmarks',
      'System events and daemon logs',
      'App preferences and core configuration',
    ];
    final scrollable = find.byType(Scrollable).first;
    for (final subtitle in expectedSubtitles) {
      await tester.scrollUntilVisible(
        find.text(subtitle),
        200,
        scrollable: scrollable,
      );
      expect(find.text(subtitle), findsOneWidget,
          reason: 'advanced tools entry "$subtitle" disappeared');
    }

    // The Egresses row (added v0.3.53) must survive too.
    await tester.scrollUntilVisible(
      find.byIcon(Icons.account_tree_outlined),
      200,
      scrollable: scrollable,
    );
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);

    // The list must be scrollable: on a 390x844 viewport the entries exceed the
    // viewport height, and a non-scrollable column would overflow.
    expect(find.byType(Scrollable), findsWidgets);
  });
}
