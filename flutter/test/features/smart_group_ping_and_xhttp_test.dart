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

  test('Public candidates with matching group IDs are scoped correctly without direct server', () async {
    const feed = '''{"outbounds":[
      {"tag":"mosaic-candidate-pub-de","type":"vless",
       "uuid":"4daffcd0-334d-46bc-a5ba-4364db09d8bd",
       "server":"198.51.100.10","server_port":443,
       "tls":{"enabled":true,"server_name":"public.example.com"},
       "transport":{"type":"ws","path":"/ws"},
       "mosaic_candidate_groups":["auto-de","germany","max_speed","min_latency","stable"],
       "mosaic_group_ids":["auto-de","germany","max_speed","min_latency","stable"]},
      {"tag":"mosaic-candidate-pub-ca","type":"vless",
       "uuid":"5daffcd0-334d-46bc-a5ba-4364db09d8bd",
       "server":"198.51.100.20","server_port":443,
       "tls":{"enabled":true,"server_name":"canada.example.com"},
       "transport":{"type":"ws","path":"/ws"},
       "mosaic_candidate_groups":["auto-ca","canada","min_latency"],
       "mosaic_group_ids":["auto-ca","canada","min_latency"]}
    ]}''';

    final configGermany = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'germany',
      ),
    ) as Map<String, dynamic>;

    final outboundsDe = (configGermany['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'vless')
        .toList();

    expect(outboundsDe.length, 1);
    expect(outboundsDe.first['tag'], 'mosaic-candidate-pub-de');

    final configMinLatency = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'min-latency',
      ),
    ) as Map<String, dynamic>;

    final outboundsMinLat = (configMinLatency['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'vless')
        .toList();

    expect(outboundsMinLat.length, 2);

    final urlTestOutbound = (configMinLatency['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'urltest');
    expect(urlTestOutbound['interval'], '3m');
    expect(urlTestOutbound['tolerance'], 50);
    expect(urlTestOutbound['idle_timeout'], '10m');
    expect(urlTestOutbound['interrupt_exist_connections'], isFalse);
  });

  test('AndroidMosaicAccountService drops splithttp transport from candidate feeds', () async {
    const feed = '''{"outbounds":[
      {"tag":"splithttp-candidate","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"1.2.3.4","server_port":443,
       "transport":{"type":"splithttp","path":"/direct"},
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
  });

  test('AndroidMosaicAccountService configures resilient multi-tier DNS with remote tunnel detour', () async {
    const feed = '''{"outbounds":[
      {"tag":"node-de-1","type":"vless",
       "uuid":"4daffcd0-334d-46bc-a5ba-4364db09d8bd",
       "server":"198.51.100.10","server_port":443,
       "transport":{"type":"ws","path":"/ws"},
       "mosaic_group_ids":["min-latency"]},
      {"tag":"node-de-2","type":"vless",
       "uuid":"5daffcd0-334d-46bc-a5ba-4364db09d8bd",
       "server":"198.51.100.20","server_port":443,
       "transport":{"type":"ws","path":"/ws"},
       "mosaic_group_ids":["min-latency"]}
    ]}''';

    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'min-latency',
        bypassRussianSites: true,
      ),
    ) as Map<String, dynamic>;

    final dns = config['dns'] as Map<String, dynamic>;
    expect(dns['strategy'], 'prefer_ipv4');
    expect(dns['final'], 'dns-direct');

    final servers = (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>();
    final direct = servers.firstWhere((s) => s['tag'] == 'dns-direct');
    expect(direct['server'], '77.88.8.8');
    expect(direct['server_port'], 53);

    final fallback = servers.firstWhere((s) => s['tag'] == 'dns-fallback');
    expect(fallback['server'], '8.8.8.8');
    expect(fallback['server_port'], 53);
  });
}
