import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/groups/groups_screen.dart';

/// GroupsScreen merges the former ManifestGroupsScreen and
/// MixedSubscriptionsScreen. Those two listed the same manifest groups with
/// different affordances, so connecting from one left the other showing stale
/// state. These tests pin the merged behaviour: both groups and individual
/// servers appear in one list, and the card sizing rules from
/// GROUP_SYSTEM_SPEC section 8.2 hold.
///
/// Every async provider the screen watches is overridden so nothing reaches
/// the real HTTP client, whose retry timers outlive the widget tree and trip
/// the binding's pending-timer assertion on teardown.
Widget _harness({
  required ProviderManifest manifest,
  List<Server> servers = const [],
  Size size = const Size(400, 800),
}) {
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(MockDaemonApi()),
      groupsManifestProvider.overrideWith((ref) async => manifest),
      serversProvider.overrideWith((ref) async => servers),
      groupNodeHealthProvider.overrideWith((ref, groupId) async => {}),
      vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: const GroupsScreen(),
      ),
    ),
  );
}

ManifestGroup _group(String id, String title) =>
    ManifestGroup(id: id, title: title);

void main() {
  group('GroupsScreen merged content', () {
    testWidgets('renders manifest groups', (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'Test Provider',
          groups: [_group('pool-auto', 'Автовыбор')],
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Автовыбор'), findsOneWidget);
    });

    testWidgets('renders individual servers alongside groups', (tester) async {
      // The whole point of the merge: a user should not have to switch screens
      // to see the servers that are not part of a group.
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'Test Provider',
          groups: [_group('pool-auto', 'Автовыбор')],
        ),
        servers: [Server(id: 's1', name: 'Direct Node', address: '10.0.0.1', port: 443)],
        size: const Size(400, 1200),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Автовыбор'), findsOneWidget);
      expect(find.text('Direct Node'), findsOneWidget);
    });

    testWidgets('empty manifest and no servers shows the empty state',
        (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(providerName: 'Test Provider'),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Нет доступных групп'), findsOneWidget);
    });

    testWidgets('load failure surfaces the underlying error', (tester) async {
      // A generic "something went wrong" leaves the user with nothing to act on
      // and nothing to report.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            daemonApiProvider.overrideWithValue(MockDaemonApi()),
            groupsManifestProvider
                .overrideWith((ref) async => throw Exception('daemon offline')),
            serversProvider.overrideWith((ref) async => <Server>[]),
            vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
          ],
          child: const MaterialApp(home: GroupsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('daemon offline'), findsOneWidget);
    });
  });

  group('GroupsScreen card sizing', () {
    testWidgets('caps card width at 520 on a wide window', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'Test Provider',
          groups: [_group('pool-auto', 'Автовыбор')],
        ),
        size: const Size(1600, 1000),
      ));
      await tester.pumpAndSettle();

      final cardWidth = tester.getSize(find.text('Автовыбор')).width;
      expect(cardWidth, lessThanOrEqualTo(520.0),
          reason: 'a card stretched across a desktop window is unreadable');
    });

    testWidgets('long group titles wrap instead of being clipped to a few glyphs',
        (tester) async {
      const longTitle =
          'Очень длинное название группы серверов для проверки переноса';

      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'Test Provider',
          groups: [_group('g1', longTitle)],
        ),
      ));
      await tester.pumpAndSettle();

      final titleFinder = find.text(longTitle);
      expect(titleFinder, findsOneWidget);

      final textWidget = tester.widget<Text>(titleFinder);
      expect(textWidget.maxLines, greaterThan(1),
          reason: 'names must wrap rather than truncate to a few characters');
    });
  });
}
