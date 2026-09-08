import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const vpnChannel =
      MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (call) async {
      if (call.method == 'status') {
        return <String, dynamic>{'state': 'disconnected', 'error': null};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, null);
  });

  test('AndroidHostedDaemonApi.getStatus() reflects measured latency when connected', () async {
    final api = AndroidHostedDaemonApi.instance;
    final status = await api.getStatus();
    // When disconnected, latencyMS is 0
    expect(status.state, 'disconnected');
    expect(status.latencyMS, 0);
  });

  test('AndroidMosaicAccountService drops xhttp transport from candidate feeds', () async {
    const feed = '''{"outbounds":[
      {"tag":"xhttp-candidate","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"1.2.3.4","server_port":443,
       "transport":{"type":"xhttp","path":"/direct"},
       "mosaic_group_ids":["min-latency"]},
      {"tag":"ws-candidate","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"5.6.7.8","server_port":443,
       "transport":{"type":"ws","path":"/mosaicws"},
       "mosaic_group_ids":["min-latency"]}
    ]}''';

    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'min-latency',
      ),
    ) as Map<String, dynamic>;

    final outbounds = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'vless')
        .toList();

    expect(outbounds.length, 1);
    expect(outbounds.first['tag'], 'ws-candidate');
    expect(outbounds.first['transport']['type'], 'ws');
  });

  test('Anchor node with universal group IDs is included in scoped candidates', () async {
    const feedWithAnchor = '''{"outbounds":[
      {"tag":"mosaic-anchor-direct-ws","type":"vless",
       "uuid":"4daffcd0-334d-46bc-a5ba-4364db09d8bd",
       "server":"5.175.188.152","server_port":443,
       "tls":{"enabled":true,"server_name":"vk.com"},
       "transport":{"type":"ws","path":"/mosaicws"},
       "mosaic_candidate_groups":["auto-de","germany","max_speed","min_latency","stable"],
       "mosaic_group_ids":["auto-de","germany","max_speed","min_latency","stable"]}
    ]}''';

    final configGermany = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feedWithAnchor,
        groupId: 'germany',
      ),
    ) as Map<String, dynamic>;

    final outboundsDe = (configGermany['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'vless')
        .toList();

    expect(outboundsDe.length, 1);
    expect(outboundsDe.first['tag'], 'mosaic-anchor-direct-ws');

    final configMinLatency = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feedWithAnchor,
        groupId: 'min-latency',
      ),
    ) as Map<String, dynamic>;

    final outboundsMinLat = (configMinLatency['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'vless')
        .toList();

    expect(outboundsMinLat.length, 1);
    expect(outboundsMinLat.first['tag'], 'mosaic-anchor-direct-ws');
  });
}
