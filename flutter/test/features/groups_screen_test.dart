import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/groups/groups_screen.dart';

Widget _harness({
  required ProviderManifest manifest,
  List<Subscription> subscriptions = const [],
  List<Server> servers = const [],
  Size size = const Size(800, 900),
}) {
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(MockDaemonApi()),
      groupsManifestProvider.overrideWith((ref) async => manifest),
      providerManifestForSubscriptionProvider
          .overrideWith((ref, subscriptionId) async => manifest),
      subscriptionsProvider.overrideWith((ref) async => subscriptions),
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
    ManifestGroup(id: id, title: title, category: 'smart');

void main() {
  group('GroupsScreen route inventory', () {
    testWidgets('renders Mosaic smart groups in the safe route table',
        (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'MosaicVPN',
          groups: [_group('rg-all', 'Минимальный пинг')],
        ),
        subscriptions: [
          Subscription(
            id: 'mosaic-url',
            name: 'MosaicVPN',
            url: 'https://sub.zxc1x1.ru/example',
            source: 'url',
            hidePhysicalNodes: true,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('MosaicVPN'), findsWidgets);
      expect(find.text('Минимальный пинг'), findsOneWidget);
      expect(find.text('Smart Group'), findsOneWidget);
      expect(find.text('Тип'), findsOneWidget);
      expect(find.text('Название'), findsOneWidget);
      expect(find.text('Задержка'), findsNothing,
          reason: 'secondary telemetry must not force a narrow desktop table off-screen');
      expect(find.text('Трафик'), findsNothing,
          reason: 'secondary telemetry reappears automatically on a wider window');
    });

    testWidgets('shows a third-party node only after its source is selected',
        (tester) async {
      final external = Subscription(id: 'external', name: 'Example service');
      final mosaic = Subscription(
        id: 'mosaic-url',
        name: 'MosaicVPN',
        url: 'https://sub.zxc1x1.ru/example',
        source: 'url',
        hidePhysicalNodes: true,
      );
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'MosaicVPN',
          groups: [_group('rg-all', 'Минимальный пинг')],
        ),
        subscriptions: [mosaic, external],
        servers: [
          Server(
            id: 'external-node',
            subscriptionID: 'external',
            name: 'Berlin node',
            address: '198.51.100.10',
            port: 443,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Berlin node'), findsNothing);
      await tester.tap(find.text('Example service'));
      await tester.pumpAndSettle();
      expect(find.text('Berlin node'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
    });

    testWidgets('does not expose a Mosaic direct physical node',
        (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'MosaicVPN',
          groups: [_group('rg-all', 'Минимальный пинг')],
        ),
        subscriptions: [Subscription(id: 'mosaic-direct', name: 'MosaicVPN')],
        servers: [
          Server(
            id: 'private-pool-node',
            subscriptionID: 'mosaic-direct',
            name: 'INTERNAL NODE MUST NOT RENDER',
            address: '203.0.113.25',
            port: 443,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('INTERNAL NODE MUST NOT RENDER'), findsNothing);
      expect(find.text('Минимальный пинг'), findsOneWidget);
    });

    testWidgets('opens the full context menu for a provider subscription',
        (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(
          providerName: 'MosaicVPN',
          groups: [_group('rg-all', 'Минимальный пинг')],
        ),
        subscriptions: [
          Subscription(
            id: 'provider-mosaicvpn-primary',
            name: 'MosaicVPN',
            url: 'https://sub.zxc1x1.ru/subscription',
            source: 'provider',
            providerId: 'mosaicvpn',
            hidePhysicalNodes: true,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Управление подпиской').first);
      await tester.pumpAndSettle();

      expect(find.text('Обновить'), findsWidgets);
      expect(find.text('Копировать ссылку'), findsOneWidget);
      expect(find.text('Открыть в браузере'), findsOneWidget);
      expect(find.text('Поделиться'), findsOneWidget);
      expect(find.text('Открыть профиль подписки'), findsOneWidget);
      expect(find.text('Переименовать'), findsNothing);
      expect(find.text('Удалить'), findsNothing);
    });

    testWidgets('shows a useful empty state without raw daemon errors',
        (tester) async {
      await tester.pumpWidget(_harness(
        manifest: ProviderManifest(providerName: 'MosaicVPN'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Нет подключённых источников'), findsOneWidget);
      expect(find.textContaining('DioException'), findsNothing);
    });
  });
}
