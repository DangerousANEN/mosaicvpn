import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/account/account_screen.dart';
import 'package:mosaic_vpn/features/billing/billing_screen.dart';
import 'package:mosaic_vpn/features/connections/connections_screen.dart';
import 'package:mosaic_vpn/features/cores/cores_screen.dart';
import 'package:mosaic_vpn/features/dashboard/connection_dashboard.dart';
import 'package:mosaic_vpn/features/egresses/egresses_screen.dart';
import 'package:mosaic_vpn/features/groups/groups_screen.dart';
import 'package:mosaic_vpn/features/logs/logs_screen.dart';
import 'package:mosaic_vpn/features/profiles/profiles_screen.dart';
import 'package:mosaic_vpn/features/provider_profile/provider_profile_screen.dart';
import 'package:mosaic_vpn/features/routing/routing_screen.dart';
import 'package:mosaic_vpn/features/servers/servers_screen.dart';
import 'package:mosaic_vpn/features/settings/settings_screen.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_screen.dart';
import 'package:mosaic_vpn/features/stats/stats_screen.dart';
import 'package:mosaic_vpn/features/subscriptions/subscriptions_screen.dart';

Widget _desktopHarness(Widget child) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

Future<void> _pumpSection(WidgetTester tester, Widget section) async {
  tester.view.physicalSize = const Size(1440, 960);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_desktopHarness(section));
  for (var step = 0; step < 5; step++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump();
}

void main() {
  testWidgets('every desktop section renders without a Material-layer warning',
      (tester) async {
    addTearDown(tester.view.reset);
    final sections = <String, Widget>{
      'connection': const ConnectionDashboard(),
      'servers': const ServersScreen(),
      'profiles': const ProfilesScreen(),
      'subscriptions': const SubscriptionsScreen(),
      'billing': const BillingScreen(),
      'groups': const GroupsScreen(),
      'account': const AccountScreen(),
      'provider': const ProviderProfileScreen(),
      'routing': const RoutingScreen(),
      'egresses': const EgressesScreen(),
      'connections': const ConnectionsScreen(),
      'stats': const StatsScreen(),
      'speed-test': const SpeedTestScreen(),
      'cores': const CoresScreen(),
      'logs': const LogsScreen(),
      'settings': const SettingsScreen(),
    };

    final failures = <String>[];
    for (final entry in sections.entries) {
      await _pumpSection(tester, entry.value);
      final exception = tester.takeException();
      if (exception != null) {
        failures.add('${entry.key}: $exception');
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });
}
