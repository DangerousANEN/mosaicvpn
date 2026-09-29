import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/account/accounts_screen.dart';
import 'package:mosaic_vpn/features/billing/billing_screen.dart';
import 'package:mosaic_vpn/features/connections/connections_screen.dart';
import 'package:mosaic_vpn/features/cores/cores_screen.dart';
import 'package:mosaic_vpn/features/dashboard/connection_dashboard.dart';
import 'package:mosaic_vpn/features/diagnostics/diagnostics_screen.dart';
import 'package:mosaic_vpn/features/egresses/egresses_screen.dart';
import 'package:mosaic_vpn/features/groups/groups_screen.dart';
import 'package:mosaic_vpn/features/logs/logs_screen.dart';
import 'package:mosaic_vpn/features/more/more_screen.dart';
import 'package:mosaic_vpn/features/profiles/profiles_screen.dart';
import 'package:mosaic_vpn/features/provider_profile/provider_profile_screen.dart';
import 'package:mosaic_vpn/features/routing/routing_screen.dart';
import 'package:mosaic_vpn/features/servers/servers_screen.dart';
import 'package:mosaic_vpn/features/settings/settings_screen.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_screen.dart';
import 'package:mosaic_vpn/features/stats/stats_screen.dart';
import 'package:mosaic_vpn/features/subscriptions/subscriptions_screen.dart';

/// Renders every screen at real phone sizes and fails on any exception.
///
/// Why this exists: the desktop render test swept 16 screens at 1440x960, but
/// nothing exercised the phone layouts, and the complaint was specifically
/// "some tabs are buggy" on a phone. Layout faults (a non-scrollable Column
/// overflowing a short viewport, an unbounded Row, a missing Material ancestor)
/// only appear at the narrow/short sizes a phone actually has.
///
/// Sizes cover the real range: a small 5" phone, a common 6.1", a tall 19.5:9,
/// and a tablet, so a layout that only works on one aspect ratio is caught.
const _phoneSizes = <String, Size>{
  'small-5.0': Size(360, 640),
  'common-6.1': Size(390, 844),
  'tall-19.5:9': Size(412, 915),
  'compact-landscape': Size(740, 360),
  'tablet': Size(800, 1280),
};

Widget _harness(Widget child) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
      ],
      child: MaterialApp(
        home: Scaffold(body: child),
        // No debug banner: it would sit in the tree but never affects layout.
        debugShowCheckedModeBanner: false,
      ),
    );

/// Screens reachable from the four bottom tabs and the More list.
Map<String, Widget Function()> _screens() => {
      'dashboard': () => const ConnectionDashboard(),
      'routes/groups': () => const GroupsScreen(),
      'accounts': () => const AccountsScreen(),
      'more': () => const MoreScreen(),
      'servers': () => const ServersScreen(),
      'profiles': () => const ProfilesScreen(),
      'subscriptions': () => const SubscriptionsScreen(),
      'billing': () => const BillingScreen(),
      'provider': () => const ProviderProfileScreen(),
      'routing': () => const RoutingScreen(),
      'egresses': () => const EgressesScreen(),
      'activity/connections': () => const ConnectionsScreen(),
      'stats': () => const StatsScreen(),
      'diagnostics': () => const DiagnosticsScreen(),
      'speed': () => const SpeedTestScreen(),
      'cores': () => const CoresScreen(),
      'logs': () => const LogsScreen(),
      'settings': () => const SettingsScreen(),
    };

void main() {
  // One test case per screen per size. Earlier this was a single case looping
  // over all screens, which produced misleading results: routing and servers
  // "failed" only because a previous screen's providers and timers were still
  // mounted in the same pump cycle. Each case gets a clean tester, so a failure
  // names the exact screen and viewport, and a real overflow cannot hide behind
  // an unrelated one.
  for (final size in _phoneSizes.entries) {
    for (final screen in _screens().entries) {
      testWidgets('${screen.key} renders at ${size.key}', (tester) async {
        addTearDown(tester.view.reset);
        tester.view.physicalSize = size.value;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(_harness(screen.value()));
        for (var step = 0; step < 6; step++) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.pump();

        expect(tester.takeException(), isNull,
            reason: '${screen.key} threw at ${size.value.width}x'
                '${size.value.height}');
      });
    }
  }

  testWidgets('switching between the four tabs repeatedly stays clean',
      (tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;

    // Tab switching is where "buggy tabs" reproduce: state kept alive across
    // switches, then rebuilt. Cycle it several times and watch for exceptions.
    final tabs = <Widget>[
      const ConnectionDashboard(),
      const GroupsScreen(),
      const AccountsScreen(),
      const MoreScreen(),
    ];

    final failures = <String>[];
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < tabs.length; i++) {
        await tester.pumpWidget(_harness(tabs[i]));
        await tester.pump(const Duration(milliseconds: 500));
        final exception = tester.takeException();
        if (exception != null) {
          failures.add('round $round tab $i: $exception');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });
}