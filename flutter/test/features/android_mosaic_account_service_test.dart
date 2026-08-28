import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  group('AndroidMosaicAccountService native config compatibility', () {
    test('rejects an xHTTP direct share URI with a clear error', () {
      expect(
        () => AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
          'vless://00000000-0000-0000-0000-000000000000@direct.example:443'
          '?security=tls&sni=direct.example&type=xhttp&path=%2Fdirect&host=direct.example#Mosaic%20Direct',
        ),
        throwsA(isA<FormatException>()),
      );
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
                'type': 'ws',
                'path': '/candidate',
                'host': 'candidate.example',
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
      expect((selected.single['transport'] as Map)['type'], 'ws');
      expect(selected.single.keys.any((key) => key.startsWith('mosaic_')),
          isFalse);
    });
  });
}
