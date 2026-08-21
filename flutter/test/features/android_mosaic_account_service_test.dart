import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  group('AndroidMosaicAccountService native config compatibility', () {
    test('normalizes an xHTTP direct share URI to sing-box HTTP transport', () {
      final config = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
        'vless://00000000-0000-0000-0000-000000000000@direct.example:443'
        '?security=tls&sni=direct.example&type=xhttp&path=%2Fdirect&host=direct.example#Mosaic%20Direct',
      );
      final decoded = jsonDecode(config) as Map<String, dynamic>;
      final outbound = (decoded['outbounds'] as List).first as Map;
      final transport = outbound['transport'] as Map;

      expect(transport['type'], 'http');
      expect(transport['path'], '/direct');
      expect(transport.containsKey('mode'), isFalse);
    });

    test('uses only marked scoped candidates for a Smart Group', () {
      final config = AndroidMosaicAccountService
          .buildNativeTunConfigFromSubscriptionPayload(
        jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'candidate-de',
              'server': 'candidate.example',
              'server_port': 443,
              'uuid': '00000000-0000-0000-0000-000000000001',
              'transport': {
                'type': 'xhttp',
                'path': '/candidate',
                'host': 'candidate.example',
                'mode': 'packet-up',
              },
              'mosaic_client_candidate': true,
              'mosaic_group_ids': ['germany'],
            },
            {
              'type': 'vless',
              'tag': 'candidate-other',
              'server': 'other.example',
              'server_port': 443,
              'uuid': '00000000-0000-0000-0000-000000000002',
              'mosaic_client_candidate': true,
              'mosaic_group_ids': ['canada'],
            },
          ],
        }),
        groupId: 'germany',
      );
      final decoded = jsonDecode(config) as Map<String, dynamic>;
      final outbounds = (decoded['outbounds'] as List).cast<Map>();
      final selected = outbounds
          .where((outbound) => outbound['type'] == 'vless')
          .toList(growable: false);

      expect(selected, hasLength(1));
      expect(selected.single['tag'], 'candidate-de');
      expect((selected.single['transport'] as Map)['type'], 'http');
      expect(selected.single.keys.any((key) => key.startsWith('mosaic_')),
          isFalse);
    });
  });
}
