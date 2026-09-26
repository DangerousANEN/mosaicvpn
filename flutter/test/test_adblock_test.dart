import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  AndroidMosaicAccountService.debugSkipReachabilityFilter = true;
  test('test candidates with adblock true', () async {
    final dio = Dio();
    final res = await dio.get<Map<dynamic, dynamic>>('https://sub.zxc1x1.ru/api/client-candidates/reftcT_frzSCwhav');
    final service = AndroidMosaicAccountService.instance;
    final outbounds = (res.data!['outbounds'] as List).cast<Map>();
    final groups = <String>{};
    for (final ob in outbounds) {
      final gids = ob['mosaic_group_ids'];
      if (gids is List) {
        for (final g in gids) groups.add(g.toString());
      }
    }
    for (final gid in groups) {
      final configStr = await service.buildNativeTunConfigFromScopedCandidates(
        'https://sub.zxc1x1.ru/reftcT_frzSCwhav',
        groupId: gid,
        adBlock: true,
      );
      final file = File('/tmp/adblock_config_' + gid + '.json');
      file.writeAsStringSync(configStr);
    }
    print('All adblock configs written for ${groups.length} groups');
  });
}