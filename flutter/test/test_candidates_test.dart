import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  AndroidMosaicAccountService.debugSkipReachabilityFilter = true;
  test('test full generation from client-candidates endpoint', () async {
    final dio = Dio();
    final resp = await dio.get<String>('https://sub.zxc1x1.ru/api/client-candidates/reftcT_frzSCwhav');
    final payload = resp.data!;
    expect(payload.isNotEmpty, true);

    final service = AndroidMosaicAccountService.instance;
    // Test for common groups
    for (final gid in ['compatibility', 'finland', 'auto-fi', 'stable', 'direct']) {
      try {
        final configStr = gid == 'direct'
            ? await service.buildNativeTunConfigFromSubscriptionUrl(
                'https://sub.zxc1x1.ru/reftcT_frzSCwhav',
                bypassRussianSites: true,
                autoFailover: true,
                adBlock: false,
              )
            : await service.buildNativeTunConfigFromScopedCandidates(
                'https://sub.zxc1x1.ru/reftcT_frzSCwhav',
                groupId: gid,
                bypassRussianSites: true,
                autoFailover: true,
                adBlock: false,
              );

        File('test_config_\$gid.json'.replaceAll('\$', '')).writeAsStringSync(configStr);
        print('Group \$gid generated successfully, length: \${configStr.length}');
      } catch (e, st) {
        print('Group \$gid FAILED: \$e\\n\$st');
        rethrow;
      }
    }
  });
}
