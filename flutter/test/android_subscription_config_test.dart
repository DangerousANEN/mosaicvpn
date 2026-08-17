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
    expect(vless['transport']['type'], 'xhttp');
    expect(vless['tls']['reality']['enabled'], isTrue);
    expect(config['route']['final'], 'mosaic-selected-route');
  });
}
