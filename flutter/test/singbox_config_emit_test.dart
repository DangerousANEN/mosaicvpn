import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Emits real generated TUN configs to disk so an external `sing-box check`
/// can validate them. Schema validation in the app is not enough: sing-box
/// 1.13 removed several legacy fields and only the real binary catches them.
void main() {
  const shareUri =
      'vless://372f63da-99fa-4f82-9988-457d2f70091a@5.175.188.152:443'
      '?encryption=none&type=ws&path=%2Fmosaicws&host=sub.zxc1x1.ru'
      '&security=tls&sni=vk.com&allowInsecure=1&fp=chrome#Mosaic%20Direct';

  test('emit generated configs for external sing-box validation', () {
    final out = Directory('build/singbox_check')..createSync(recursive: true);

    for (final adBlock in [false, true]) {
      for (final bypassRu in [false, true]) {
        final configJson = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
          shareUri,
          adBlock: adBlock,
          bypassRussianSites: bypassRu,
          autoFailover: true,
        );
        final config = jsonDecode(configJson) as Map<String, dynamic>;
        final name = 'tun_adblock-${adBlock}_bypassru-$bypassRu.json';
        final file = File('${out.path}/$name');
        file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(config));
        stdout.writeln('WROTE ${file.path}');

        // Guard the two fields that crashed real releases.
        final inbound = (config['inbounds'] as List).first as Map;
        expect(inbound.containsKey('endpoint_independent_nat'), isFalse,
            reason: 'removed in sing-box 1.13 — crashed v0.3.53');
        final dns = config['dns'] as Map;
        for (final server in (dns['servers'] as List).cast<Map>()) {
          expect(server['address']?.toString() ?? '', isNot(startsWith('rcode://')),
              reason: 'rcode:// pseudo-servers removed in sing-box 1.12+');
        }
      }
    }
  });
}
