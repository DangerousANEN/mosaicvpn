import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'read') return null;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test(
      'persists Android-local groups and servers as a connectable local source',
      () async {
    final api = AndroidHostedDaemonApi.instance;
    final group = await api.createGroup('Работа');
    await api.addServer(Server(
      id: '',
      name: 'Personal VLESS',
      protocol: Protocol.vless,
      tag: group.id,
      importUri:
          'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.22:443?encryption=none#Personal',
    ));

    final subscriptions = await api.listSubscriptions();
    final local =
        subscriptions.singleWhere((value) => value.id == 'local-default');
    final groups = await api.listGroups();
    final servers = await api.listServers(subscriptionID: local.id);

    expect(local.name, 'Локальные профили');
    expect(local.serverCount, 1);
    expect(groups.single.id, group.id);
    expect(servers.single.subscriptionID, 'local-default');
    expect(servers.single.groupId, group.id);
    expect(servers.single.importUri, contains('vless://'));
  });

  test('keeps a MosaicVPN URL as a normal user-owned subscription', () async {
    final api = AndroidHostedDaemonApi.instance;
    final subscription = await api.addSubscription(
      'Моя MosaicVPN подписка',
      'https://sub.zxc1x1.ru/reftcT_frzSCwhav',
    );

    final stored = await api.listSubscriptions();
    final mosaic = stored.singleWhere((value) => value.id == subscription.id);
    expect(mosaic.isProviderSource, isFalse);
    expect(mosaic.providerId, isEmpty);
    expect(mosaic.hidePhysicalNodes, isFalse);
    expect(mosaic.url, 'https://sub.zxc1x1.ru/reftcT_frzSCwhav');

    await api.deleteSubscription(subscription.id);
    expect(await api.listSubscriptions(), isEmpty);
  });

  test('migrates legacy Mosaic provider rows into deletable URL subscriptions',
      () async {
    const subscriptionsKey = 'mosaic.android.subscriptions.v1';
    SharedPreferences.setMockInitialValues(<String, Object>{
      subscriptionsKey: jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'id': 'provider-mosaicvpn-primary',
          'name': 'MosaicVPN',
          'url': 'https://sub.zxc1x1.ru/legacy-opaque-link',
          'auto_refresh': true,
          'refresh_interval_seconds': 3600,
          'server_count': 0,
          'last_fetched': '2026-08-19T00:00:00.000Z',
          'has_error': false,
          'last_error': '',
          'source': 'provider',
          'provider_id': 'mosaicvpn',
          'provider_account_id': 'telegram:123',
          'hide_physical_nodes': true,
        },
      ]),
    });

    final api = AndroidHostedDaemonApi.instance;
    final migrated = (await api.listSubscriptions()).single;
    expect(migrated.isProviderSource, isFalse);
    expect(migrated.source, 'url');
    expect(migrated.id, 'provider-mosaicvpn-primary');

    await api.deleteSubscription(migrated.id);
    expect(await api.listSubscriptions(), isEmpty);
  });

  test('deleting an Android-local group keeps its servers but ungroups them',
      () async {
    final api = AndroidHostedDaemonApi.instance;
    final group = await api.createGroup('Temporary');
    await api.addServer(Server(
      id: 'server-to-ungroup',
      name: 'Personal VLESS',
      protocol: Protocol.vless,
      tag: group.id,
      importUri:
          'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.23:443?encryption=none#Personal',
    ));

    await api.deleteGroup(group.id);

    final groups = await api.listGroups();
    final servers = await api.listServers(subscriptionID: 'local-default');
    expect(groups, isEmpty);
    expect(servers.single.groupId, isEmpty);
    expect(servers.single.tag, isEmpty);
  });

  test('testDirectRoute refuses Smart Group IDs instead of probing them',
      () async {
    final api = AndroidHostedDaemonApi.instance;
    // A scoped Smart Group id must never be probed as a single server.
    expect(
      () => api.testDirectRoute('provider-sub-1:min-latency'),
      throwsA(isA<StateError>()),
    );
  });
}
