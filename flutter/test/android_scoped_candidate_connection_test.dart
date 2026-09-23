import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

class FeedAdapter implements HttpClientAdapter {
  FeedAdapter(this.feed, {this.status = 200});
  final Map<String, dynamic> feed;
  final int status;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.uri.path);
    final isCandidates = options.uri.path.startsWith('/api/client-candidates/');
    if (options.uri.path == '/api/manifest.json') {
      return ResponseBody.fromString(jsonEncode({'groups': [
        {'id': 'free-lte', 'title': 'Free LTE', 'route_type': 'smart'},
        {'id': 'germany', 'title': 'Germany', 'route_type': 'smart'},
      ]}), 200, headers: {Headers.contentTypeHeader: ['application/json']});
    }
    return ResponseBody.fromString(
      jsonEncode(isCandidates ? feed : {'outbounds': [node('outside')]}),
      isCandidates ? status : 200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> node(String tag, {List<String>? groups}) => {
  'tag': tag,
  'type': 'vless',
  'server': '198.51.100.9',
  'server_port': 443,
  'uuid': '7e85ed3f-3829-45b1-8b1c-6a2e45ebc967',
  if (groups != null) 'mosaic_group_ids': groups,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('named groups reject a feed with no membership metadata', () async {
    final account = AndroidMosaicAccountService.withHttpAdapter(
      FeedAdapter({'outbounds': [node('unscoped')]}));
    for (final group in ['free-lte', 'min-latency']) {
      expect(await account.fetchGroupCandidates(
        'https://example.invalid/fixture', groupId: group), isEmpty);
    }
  });

  test('candidate API errors propagate without ordinary subscription fallback', () async {
    final adapter = FeedAdapter({'error': 'unavailable'}, status: 503);
    final account = AndroidMosaicAccountService.withHttpAdapter(adapter);
    await expectLater(account.buildNativeTunConfigFromScopedCandidates(
      'https://example.invalid/fixture', groupId: 'free-lte'),
      throwsA(isA<DioException>()));
    expect(adapter.paths, ['/api/client-candidates/fixture']);
  });

  test('whole-group config retains only scoped candidates', () async {
    final adapter = FeedAdapter({'outbounds': [
      node('first', groups: ['free-lte']), node('second', groups: ['free-lte']),
      node('foreign', groups: ['germany']),
    ]});
    final account = AndroidMosaicAccountService.withHttpAdapter(adapter);
    final config = jsonDecode(await account.buildNativeTunConfigFromScopedCandidates(
      'https://example.invalid/fixture', groupId: 'free-lte')) as Map;
    final physical = (config['outbounds'] as List).where((value) => value['type'] == 'vless');
    expect(physical.map((value) => value['tag']).toList(), ['first', 'second']);
  });

  test('empty scoped feed fails without fetching ordinary subscription', () async {
    final adapter = FeedAdapter({'outbounds': []});
    final account = AndroidMosaicAccountService.withHttpAdapter(adapter);
    await expectLater(
      account.buildNativeTunConfigFromScopedCandidates(
        'https://example.invalid/fixture', groupId: 'free-lte'),
      throwsA(isA<StateError>()),
    );
    expect(adapter.paths, ['/api/client-candidates/fixture']);
  });
}
