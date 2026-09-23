import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  test('Free LTE never accepts an unscoped legacy candidate feed', () {
    final payload = jsonEncode({'outbounds': [
      {'tag': 'unscoped', 'type': 'vless', 'server': '198.51.100.9',
       'server_port': 443, 'uuid': '7e85ed3f-3829-45b1-8b1c-6a2e45ebc967'}
    ]});
    expect(() => AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
      payload, groupId: 'free-lte'), throwsA(isA<StateError>()));
  });
}
