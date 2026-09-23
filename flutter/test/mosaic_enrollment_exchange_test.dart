import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/mosaic_enrollment_exchange.dart';

class _MockExchangeAdapter implements HttpClientAdapter {
  _MockExchangeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('MosaicEnrollmentExchange.isSupportedCallback', () {
    test('accepts verified https website callbacks', () {
      expect(
        MosaicEnrollmentExchange.isSupportedCallback(
          Uri.parse('https://sub.zxc1x1.ru/enroll/callback?code=12345678'),
        ),
        isTrue,
      );
    });

    test('accepts mosaicvpn and mosaic custom schemes', () {
      expect(
        MosaicEnrollmentExchange.isSupportedCallback(
          Uri.parse('mosaicvpn://enroll/callback?code=12345678'),
        ),
        isTrue,
      );
      expect(
        MosaicEnrollmentExchange.isSupportedCallback(
          Uri.parse('mosaic://enroll/callback?code=12345678'),
        ),
        isTrue,
      );
    });

    test('rejects unsupported domains or schemes', () {
      expect(
        MosaicEnrollmentExchange.isSupportedCallback(
          Uri.parse('https://evil.com/enroll/callback?code=12345678'),
        ),
        isFalse,
      );
      expect(
        MosaicEnrollmentExchange.isSupportedCallback(
          Uri.parse('mosaicvpn://auth/callback?code=12345678'),
        ),
        isFalse,
      );
    });
  });

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

    test('creates stable key for 8-char bot pairing links without state', () {
      const code = 'ABCD1234';
      final callback = Uri.parse(
        'https://sub.zxc1x1.ru/enroll/callback?code=$code',
      );

      expect(
        MosaicEnrollmentExchange.callbackDeliveryKey(callback),
        '$code::',
      );
    });

    test('deduplicates identical cold and warm deliveries', () {
      const code = 'K1L2M3N4O5P6Q7R8S9T0U1V2';
      const state = 'ZzYyXxWwVvUuTtSsRrQqPpOo';
      final coldUri = Uri.parse('mosaicvpn://enroll/callback?code=$code&state=$state');
      final warmUri = Uri.parse('https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state');

      final coldKey = MosaicEnrollmentExchange.callbackDeliveryKey(coldUri);
      final warmKey = MosaicEnrollmentExchange.callbackDeliveryKey(warmUri);

      expect(coldKey, equals(warmKey));
      expect(coldKey, '$code::$state');
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

  group('MosaicEnrollmentExchange.redeem & burn-before-durable-save', () {
    test('redeems valid exchange response with durable tokens', () async {
      const code = 'X1Y2Z3A4B5C6D7E8F9G0H1I2';
      const state = 'StateToken12345678901234567890';
      final callback = Uri.parse(
        'https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state',
      );

      MosaicEnrollmentExchange.setMockHttpClientAdapter(_MockExchangeAdapter((options) async {
        expect(options.path, '/api/app-auth/exchange');
        expect(options.data, {'code': code, 'state': state});
        final body = jsonEncode({
          'purpose': 'enroll',
          'subscription_url': 'https://sub.zxc1x1.ru/test-token-direct',
          'subscription_name': 'Mosaic Test Plan',
          'provider_id': 'mosaicvpn',
          'provider_account_id': 'account_99',
          'direct_token': 'test-token-direct',
          'session_token': 'session_token_xyz',
          'username': 'tg_user_123',
        });
        return ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }));

      final result = await MosaicEnrollmentExchange.redeem(callback);
      expect(result.subscriptionUrl, 'https://sub.zxc1x1.ru/test-token-direct');
      expect(result.subscriptionName, 'Mosaic Test Plan');
      expect(result.providerId, 'mosaicvpn');
      expect(result.providerAccountId, 'account_99');
      expect(result.directToken, 'test-token-direct');
      expect(result.sessionToken, 'session_token_xyz');
      expect(result.username, 'tg_user_123');
    });

    test('throws FormatException if purpose is not enroll', () async {
      const code = 'X1Y2Z3A4B5C6D7E8F9G0H1I2';
      const state = 'StateToken12345678901234567890';
      final callback = Uri.parse(
        'https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state',
      );

      MosaicEnrollmentExchange.setMockHttpClientAdapter(_MockExchangeAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode({'purpose': 'login'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }));

      expect(
        () => MosaicEnrollmentExchange.redeem(callback),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
