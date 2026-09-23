import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/mosaic_enrollment_exchange.dart';

class _CountingMockAdapter implements HttpClientAdapter {
  _CountingMockAdapter({required this.onExchange});

  int exchangeCallCount = 0;
  final ResponseBody Function(int callIndex, RequestOptions options) onExchange;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('/api/app-auth/exchange')) {
      exchangeCallCount++;
      return onExchange(exchangeCallCount, options);
    }
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('Enrollment Queue & Cold/Warm Duplicate Delivery Resilience', () {
    test('deduplicates identical cold and warm deliveries via callbackDeliveryKey', () {
      final queue = <Uri>[];
      final completed = <String>{};
      int processCount = 0;

      void enqueue(Uri callback) {
        if (!MosaicEnrollmentExchange.isSupportedCallback(callback)) return;
        final key = MosaicEnrollmentExchange.callbackDeliveryKey(callback);
        if (key != null && completed.contains(key)) return;
        if (queue.any((p) => MosaicEnrollmentExchange.callbackDeliveryKey(p) == key)) {
          return;
        }
        queue.add(callback);
      }

      void processAll() {
        while (queue.isNotEmpty) {
          final item = queue.removeAt(0);
          final key = MosaicEnrollmentExchange.callbackDeliveryKey(item);
          if (key != null) {
            completed.add(key);
            processCount++;
          }
        }
      }

      const code = 'ColdWarmDelivery12345678';
      const state = 'StateMatchingValue87654321';

      // 1. Cold launch initial link
      enqueue(Uri.parse('https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state'));
      // 2. Warm stream event delivering same URI concurrently
      enqueue(Uri.parse('mosaicvpn://enroll/callback?code=$code&state=$state'));
      // 3. Resumed lifecycle event delivering same URI
      enqueue(Uri.parse('https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state'));

      expect(queue.length, 1, reason: 'Duplicate deliveries must be deduplicated in queue');
      processAll();
      expect(processCount, 1, reason: 'Only one actual exchange must occur');
      expect(completed.contains('$code::$state'), isTrue);

      // Subsequent arrival after completion must be ignored
      enqueue(Uri.parse('mosaicvpn://enroll/callback?code=$code&state=$state'));
      expect(queue.isEmpty, isTrue, reason: 'Completed callback key must not re-enter queue');
    });

    test('queues distinct callbacks and processes sequentially', () {
      final queue = <Uri>[];
      final processedOrder = <String>[];

      void enqueue(Uri callback) {
        if (!MosaicEnrollmentExchange.isSupportedCallback(callback)) return;
        final key = MosaicEnrollmentExchange.callbackDeliveryKey(callback);
        if (queue.any((p) => MosaicEnrollmentExchange.callbackDeliveryKey(p) == key)) {
          return;
        }
        queue.add(callback);
      }

      enqueue(Uri.parse('mosaicvpn://enroll/callback?code=CODE1111111111111111&state=STATE1111111111111111'));
      enqueue(Uri.parse('mosaicvpn://enroll/callback?code=CODE2222222222222222&state=STATE2222222222222222'));

      expect(queue.length, 2);
      while (queue.isNotEmpty) {
        final item = queue.removeAt(0);
        processedOrder.add(MosaicEnrollmentExchange.callbackDeliveryKey(item)!);
      }

      expect(processedOrder, [
        'CODE1111111111111111::STATE1111111111111111',
        'CODE2222222222222222::STATE2222222222222222',
      ]);
    });

    test('burn-before-durable-save ensures complete credential material is delivered', () async {
      const code = 'DurableSaveCode12345678';
      const state = 'DurableSaveState87654321';
      final callback = Uri.parse('https://sub.zxc1x1.ru/enroll/callback?code=$code&state=$state');

      final adapter = _CountingMockAdapter(
        onExchange: (callIndex, options) {
          return ResponseBody.fromString(
            jsonEncode({
              'purpose': 'enroll',
              'subscription_url': 'https://sub.zxc1x1.ru/durable-direct-token',
              'subscription_name': 'Mosaic Permanent Plan',
              'provider_id': 'mosaicvpn',
              'provider_account_id': 'permanent_acc',
              'direct_token': 'durable-direct-token',
              'session_token': 'durable_session_token',
              'username': 'mosaic_hero',
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        },
      );
      MosaicEnrollmentExchange.setMockHttpClientAdapter(adapter);

      final enrollment = await MosaicEnrollmentExchange.redeem(callback);
      expect(adapter.exchangeCallCount, 1);
      expect(enrollment.directToken, 'durable-direct-token');
      expect(enrollment.sessionToken, 'durable_session_token');
      expect(enrollment.username, 'mosaic_hero');
      expect(enrollment.subscriptionUrl, 'https://sub.zxc1x1.ru/durable-direct-token');
    });
  });
}
