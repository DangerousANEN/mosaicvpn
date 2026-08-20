import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/mosaic_enrollment_exchange.dart';

void main() {
  group('MosaicEnrollmentExchange.callbackDeliveryKey', () {
    test('creates one stable key for equivalent custom protocol callbacks', () {
      const code = 'A1B2C3D4E5F6G7H8I9J0K1L2';
      const state = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPp';
      final callback = Uri.parse(
        'mosaicvpn://enroll/callback?code=$code&state=$state',
      );

      expect(
        MosaicEnrollmentExchange.callbackDeliveryKey(callback),
        '$code::$state',
      );
    });

    test('rejects malformed or unrelated callbacks', () {
      expect(
        MosaicEnrollmentExchange.callbackDeliveryKey(
          Uri.parse('mosaicvpn://enroll/callback?code=short&state=short'),
        ),
        isNull,
      );
      expect(
        MosaicEnrollmentExchange.callbackDeliveryKey(
          Uri.parse('mosaicvpn://auth/callback?code=abcdef'),
        ),
        isNull,
      );
    });
  });
}
