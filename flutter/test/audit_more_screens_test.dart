import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/theme/atlas_theme.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/features/more/more_screen.dart';
import 'package:mosaic_vpn/features/profiles/profiles_screen.dart';
import 'package:mosaic_vpn/features/stats/stats_screen.dart';
import 'package:mosaic_vpn/features/connections/connections_screen.dart';
import 'package:mosaic_vpn/features/egresses/egresses_screen.dart';
import 'package:mosaic_vpn/features/routing/routing_screen.dart';
import 'package:mosaic_vpn/features/diagnostics/diagnostics_screen.dart';
import 'package:mosaic_vpn/features/logs/logs_screen.dart';
import 'package:mosaic_vpn/features/settings/settings_screen.dart';

Widget _wrapWithHarness(Widget child, {required double width, double scale = 1.0}) {
  final mock = MockDaemonApi();
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(mock),
      profilesProvider.overrideWith((ref) => Future.value([
            Profile(
              id: 'prof-1',
              name: 'Fast Streaming Berlin',
              icon: '🚀',
              color: '#3B82F6',
              tunnelMode: 'tun',
              killSwitch: true,
              allowLAN: true,
              ruleIDs: ['r1', 'r2'],
            ),
            Profile(
              id: 'prof-2',
              name: 'Gaming Tokyo Low Latency',
              icon: '🎮',
              color: '#10B981',
              tunnelMode: 'tun',
              killSwitch: false,
              allowLAN: false,
              ruleIDs: ['r3'],
            ),
          ])),
      connectionsProvider.overrideWith((ref) => Stream.value([
            Connection(
              id: 'c1',
              domain: 'api.github.com',
              port: 443,
              process: 'git.exe',
              outbound: 'proxy',
              chain: 'Frankfurt-01',
              upload: 1024,
              download: 20480,
              network: 'tcp',
            ),
          ])),
      egressesProvider.overrideWith((ref) => Future.value([
            Egress(
              id: 'eg-1',
              name: 'Browser Proxy',
              port: 2080,
              type: 'mixed',
              serverID: 's1',
            ),
          ])),
      serversProvider.overrideWith((ref) => Future.value([
            Server(
              id: 's1',
              name: 'Frankfurt 01',
              country: 'DE',
              address: '1.2.3.4',
              port: 443,
              protocol: Protocol.vless,
            ),
          ])),
      rulesProvider.overrideWith((ref) => Future.value([
            Rule(
              id: 'r1',
              name: 'Telegram Direct',
              action: RuleAction.direct,
              match: const RuleMatch(domain: ['t.me', 'telegram.org']),
            ),
          ])),
    ],
    child: MaterialApp(
      theme: AtlasTheme.darkThemeData,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('en'), Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, 700),
          textScaler: TextScaler.linear(scale),
        ),
        child: c!,
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  final screens = <String, Widget Function()>{
    'MoreScreen': () => const MoreScreen(),
    'ProfilesScreen': () => const ProfilesScreen(),
    'StatsScreen': () => const StatsScreen(),
    'ConnectionsScreen': () => const ConnectionsScreen(),
    'EgressesScreen': () => const EgressesScreen(),
    'RoutingScreen': () => const RoutingScreen(),
    'DiagnosticsScreen': () => const DiagnosticsScreen(),
    'LogsScreen': () => const LogsScreen(),
    'SettingsScreen': () => const SettingsScreen(),
  };

  for (final width in [320.0, 360.0, 390.0]) {
    for (final scale in [1.0, 1.3]) {
      group('Audit screens at width $width scale $scale', () {
        for (final entry in screens.entries) {
          testWidgets('${entry.key} builds without exception/overflow',
              (tester) async {
            tester.view.physicalSize = Size(width, 700);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(
              _wrapWithHarness(entry.value(), width: width, scale: scale),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));

            final error = tester.takeException();
            if (error != null) {
              // ignore: avoid_print
              print('FAIL [${entry.key}] w=$width s=$scale: $error');
            }
            expect(error, isNull,
                reason: '${entry.key} overflowed at width $width scale $scale');
          });
        }
      });
    }
  }
}
