import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'android_scoped_candidate_connection_test.dart' show FeedAdapter, node;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');
  final configs = <Map<String, dynamic>>[];
  late FeedAdapter adapter;
  late AndroidHostedDaemonApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'mosaic.android.subscriptions.v1': jsonEncode([
        {'id': 'fixture', 'name': 'Fixture', 'url': 'https://sub.zxc1x1.ru/fixture', 'source': 'url'}
      ]),
    });
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    configs.clear();
    adapter = FeedAdapter({'outbounds': [
      node('first', groups: ['free-lte']),
      node('second', groups: ['free-lte']),
      node('other', groups: ['germany']),
    ]});
    api = AndroidHostedDaemonApi.withAccount(
      AndroidMosaicAccountService.withHttpAdapter(adapter));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepare') return true;
        if (call.method == 'status') return {'state': 'disconnected'};
        if (call.method == 'start') {
          configs.add(jsonDecode((call.arguments as Map)['config'] as String));
          return {'state': 'error', 'error': 'Туннель запустился, но не пропускает трафик'};
        }
        return null;
      });
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
  });

  test('explicit candidate launches only its own outbound', () async {
    final shard = await api.getCandidateShard('provider:fixture:free-lte', 'test-installation');
    await expectLater(api.connectGroupCandidate('provider:fixture:free-lte',
      shard.candidateIds.last), throwsStateError);
    expect(configs, hasLength(1));
    final physical = (configs.single['outbounds'] as List)
      .where((value) => value['type'] == 'vless').toList();
    expect(physical.map((value) => value['tag']).toList(), ['second']);
  });

  for (final candidate in ['other', 'missing', '']) {
    test('rejects out-of-scope or invalid candidate: $candidate', () async {
      await expectLater(api.connectGroupCandidate(
        'provider:fixture:free-lte', candidate), throwsStateError);
      expect(configs, isEmpty);
      expect(adapter.paths, isNot(contains('/fixture')));
    });
  }

  test('removed shard candidate is rejected before native startup', () async {
    await api.getCandidateShard('provider:fixture:free-lte', 'test-installation');
    (adapter.feed['outbounds'] as List).removeWhere((entry) => entry['tag'] == 'second');
    await expectLater(api.connectGroupCandidate(
      'provider:fixture:free-lte', 'second'), throwsStateError);
    expect(configs, isEmpty);
  });

  test('ambiguous duplicate candidate tags are rejected', () async {
    (adapter.feed['outbounds'] as List).add(node('second', groups: ['free-lte']));
    await expectLater(api.connectGroupCandidate(
      'provider:fixture:free-lte', 'second'), throwsStateError);
    expect(configs, isEmpty);
  });

  test('group startup failure never substitutes ordinary subscription', () async {
    await expectLater(api.connectGroup('provider:fixture:free-lte'), throwsStateError);
    expect(configs, hasLength(1));
    expect(adapter.paths, isNot(contains('/fixture')));
  });
}
