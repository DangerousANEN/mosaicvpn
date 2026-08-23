import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  test('rejects an XHTTP VLESS URI with a clear error', () {
    const shareUri =
        'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@5.175.188.152:443'
        '?encryption=none&security=reality&sni=cdn.zxc1x1.ru'
        '&pbk=test-public-key&sid=abcd&type=xhttp&path=%2Fcdn-direct'
        '&host=cdn.zxc1x1.ru&mode=auto#Mosaic%20test';

    // sing-box (libbox) cannot speak Xray's XHTTP wire protocol. Relabelling
    // it as `http` used to yield a config that connected but never carried
    // data; the parser must refuse instead.
    expect(
      () => AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
          shareUri),
      throwsA(isA<FormatException>()),
    );
  });

  test(
      'builds a native TUN config from a fetched subscription payload without a cabinet session',
      () {
    const payload =
        'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.44:443?security=tls&sni=example.test#URL%20subscription';
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        payload,
      ),
    ) as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final vless = outbounds.cast<Map<String, dynamic>>().firstWhere(
          (outbound) => outbound['type'] == 'vless',
        );

    expect(vless['server'], '198.51.100.44');
    expect(config['inbounds'], isNotEmpty);
  });

  test('builds a native TUN sing-box config from a SIP002 Shadowsocks URI', () {
    const shareUri =
        'ss://YWVzLTI1Ni1nY206c2VjcmV0QDE5OC41MS4xMDAuMTA6ODM4OA#SS%20test';
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(shareUri),
    ) as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final ss = outbounds.cast<Map<String, dynamic>>().firstWhere(
          (outbound) => outbound['type'] == 'shadowsocks',
        );

    expect(ss['server'], '198.51.100.10');
    expect(ss['server_port'], 8388);
    expect(ss['method'], 'aes-256-gcm');
    expect(ss['password'], 'secret');
  });

  test('builds a native TUN sing-box config from a VMess URI', () {
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': 'VMess test',
      'add': '203.0.113.12',
      'port': '443',
      'id': 'e619d9bd-2950-4098-bcf2-e943fd6b5647',
      'aid': '0',
      'scy': 'auto',
      'net': 'ws',
      'host': 'edge.example',
      'path': '/ws',
      'tls': 'tls',
      'sni': 'edge.example',
    })));
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
          'vmess://$payload'),
    ) as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final vmess = outbounds.cast<Map<String, dynamic>>().firstWhere(
          (outbound) => outbound['type'] == 'vmess',
        );

    expect(vmess['server'], '203.0.113.12');
    expect(vmess['server_port'], 443);
    expect(vmess['transport']['type'], 'ws');
    expect(vmess['tls']['enabled'], isTrue);
  });

  test('parses a candidate JSON feed delivered as a decoded dio Map', () {
    // Regression: when dio hands the /api/client-candidates document over as
    // an already decoded Map, stringifying it produced a fake share-URI line
    // and the connection failed with
    // "FormatException: Некорректная ссылка сервера: {outbounds: [...".
    const feed = '''{"outbounds":[
      {"tag":"mosaic-candidate-9d4f5933f54c","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"164.68.127.108","server_port":24144,
       "mosaic_client_candidate":true,
       "mosaic_candidate_groups":["auto-fr","max_speed","min_latency"],
       "mosaic_group_ids":["auto-fr","max_speed","min_latency"],
       "mosaic_stable":false,"mosaic_speed_eligible":true,
       "mosaic_country":"FR","mosaic_speed_mbps":0.03}
    ]}''';
    final decoded = jsonDecode(feed) as Map<String, dynamic>;
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        jsonEncode(decoded),
        groupId: 'min-latency',
      ),
    ) as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final vless = outbounds.cast<Map<String, dynamic>>().firstWhere(
          (outbound) => outbound['type'] == 'vless',
        );

    expect(vless['tag'], 'mosaic-candidate-9d4f5933f54c');
    expect(vless['server'], '164.68.127.108');
    // mosaic_* selection hints must not leak into the sing-box schema.
    expect(vless.containsKey('mosaic_group_ids'), isFalse);
    expect(vless.containsKey('mosaic_client_candidate'), isFalse);
  });

  test('matches snake_case collector group ids against hyphenated manifest ids',
      () {
    const feed = '''{"outbounds":[
      {"tag":"mosaic-candidate-aa","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"164.68.127.108","server_port":24144,
       "mosaic_group_ids":["min_latency","max_speed"]},
      {"tag":"mosaic-candidate-bb","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"198.51.100.9","server_port":24144,
       "mosaic_group_ids":["auto-fr"]}
    ]}''';
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'min-latency',
      ),
    ) as Map<String, dynamic>;
    final tags = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((outbound) => outbound['type'] != 'urltest')
        .where((outbound) => outbound['type'] != 'direct')
        .map((outbound) => outbound['tag'])
        .toList();

    expect(tags, ['mosaic-candidate-aa']);
  });

  test('drops XHTTP candidates from a JSON feed and keeps usable ones', () {
    const feed = '''{"outbounds":[
      {"tag":"xhttp-node","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"198.51.100.10","server_port":443,
       "tls":{"enabled":true,"server_name":"vk.com"},
       "transport":{"type":"xhttp","path":"/direct","mode":"auto"}},
      {"tag":"ws-node","type":"vless",
       "uuid":"7e85ed3f-3829-45b1-8b1c-6a2e45ebc967",
       "server":"198.51.100.11","server_port":443,
       "tls":{"enabled":true,"server_name":"sub.zxc1x1.ru"},
       "transport":{"type":"ws","path":"/mosaicws","host":"sub.zxc1x1.ru"}}
    ]}''';
    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
      ),
    ) as Map<String, dynamic>;
    final vless = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((outbound) => outbound['type'] == 'vless')
        .toList();

    // Only the ws node survives; xhttp cannot be spoken by libbox.
    expect(vless.single['tag'], 'ws-node');
    final transport = vless.single['transport'] as Map<String, dynamic>;
    // sing-box rejects an unknown `host` field on the ws transport: the value
    // belongs in headers.
    expect(transport.containsKey('host'), isFalse);
    expect(transport['headers']['Host'], 'sub.zxc1x1.ru');
  });
}
