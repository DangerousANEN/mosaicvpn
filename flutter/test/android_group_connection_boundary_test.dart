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
    AndroidMosaicAccountService.debugSkipReachabilityFilter = true;
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
    AndroidMosaicAccountService.debugAssumeAllReachable = false;
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

  test('a dead-traffic candidate is rotated out, not retried', () async {
    // The diagnosed production failure: the core starts, the tunnel comes up,
    // but the node carries no traffic ("connects, lags, dies in 3s"). The
    // connect layer must drop THAT node and start again with the next one,
    // so the user ends up with a working tunnel instead of a teardown.
    AndroidMosaicAccountService.debugSkipReachabilityFilter = false;
    AndroidMosaicAccountService.debugAssumeAllReachable = true;
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prepare') return true;
      if (call.method == 'status') {
        // First session: verify fails (error). Second: verified connected.
        if (starts <= 1) return {'state': 'error', 'error': 'трафик не проходит'};
        return {'state': 'connected'};
      }
      if (call.method == 'start') {
        starts++;
        configs.add(jsonDecode((call.arguments as Map)['config'] as String));
        return {'state': 'verifying'};
      }
      return null;
    });

    await api.connectGroup('provider:fixture:free-lte');

    expect(starts, 2, reason: 'rotation must retry exactly once for one dead node');
    final firstTags = _candidateTags(configs.first);
    final secondTags = _candidateTags(configs.last);
    expect(secondTags.length, lessThan(firstTags.length),
        reason: 'the rejected node must be excluded from the retry');
    expect(firstTags.difference(secondTags), hasLength(1),
        reason: 'exactly one node (the fastest) is dropped per rotation');
  });
}

/// Candidate tags present in the sing-box config built for a group. Fixture
/// nodes carry plain tags ('first'/'second'), production ones are prefixed
/// with mosaic-candidate-, so both shapes are collected here.
Set<String> _candidateTags(Map<String, dynamic> config) {
  final outbounds = (config['outbounds'] as List).cast<Map>();
  return outbounds
      .map((o) => o['tag']?.toString() ?? '')
      .where((tag) =>
          tag.isNotEmpty &&
          tag != 'direct' &&
          tag != 'block' &&
          tag != 'proxy' &&
          !tag.contains('selected-route'))
      .toSet();
}
