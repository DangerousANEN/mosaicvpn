import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  AndroidMosaicAccountService.debugSkipReachabilityFilter = true;
  test('test all group candidates validation against singbox check', () async {
    final dio = Dio();
    final resp = await dio.get<String>('https://sub.zxc1x1.ru/api/client-candidates/reftcT_frzSCwhav');
    final service = AndroidMosaicAccountService.instance;
    final groups = [
      'compatibility',
      'finland',
      'auto-fi',
      'stable',
      'auto-de',
      'germany',
      'auto-nl',
      'netherlands',
      'auto-gb',
      'great-britain',
      'auto-ca',
      'canada',
      'auto-sg',
      'singapore',
      'auto-jp',
      'japan',
      'auto-pl',
      'poland',
      'auto-fr',
      'france',
      'direct'
    ];

    for (final gid in groups) {
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

      final file = File('/tmp/config_' + gid + '.json');
      file.writeAsStringSync(configStr);
      print('Wrote /tmp/config_' + gid + '.json (' + configStr.length.toString() + ' bytes)');
    }
  });
}
