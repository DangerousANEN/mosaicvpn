import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  test('builds a native TUN sing-box config from a VLESS subscription URI', () {
    const shareUri =
        'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@5.175.188.152:443'
        '?encryption=none&security=reality&sni=cdn.zxc1x1.ru'
        '&pbk=test-public-key&sid=abcd&type=xhttp&path=%2Fcdn-direct'
        '&host=cdn.zxc1x1.ru&mode=auto#Mosaic%20test';

    final config = jsonDecode(
      AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(shareUri),
    ) as Map<String, dynamic>;
    final inbounds = config['inbounds'] as List<dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final vless = outbounds.cast<Map<String, dynamic>>().firstWhere(
          (outbound) => outbound['type'] == 'vless',
        );

    expect(inbounds.single['type'], 'tun');
    expect(vless['server'], '5.175.188.152');
    expect(vless['server_port'], 443);
    expect(vless['uuid'], 'e619d9bd-2950-4098-bcf2-e943fd6b5647');
    // VLESS URI `encryption=none` is not a sing-box 1.13 outbound field.
    expect(vless.containsKey('encryption'), isFalse);
    expect(vless['transport']['type'], 'http');
    expect(vless['transport'].containsKey('mode'), isFalse);
    expect(vless['tls']['reality']['enabled'], isTrue);
    expect(config['route']['final'], 'mosaic-selected-route');
    expect(config['route']['default_domain_resolver'], 'mosaic-doh-bootstrap');
    expect((config['route']['rules'] as List).first['action'], 'hijack-dns');
    expect((config['dns']['servers'] as List).single['type'], 'https');
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
}
