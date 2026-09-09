import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

void main() {
  group('Edge cases and resilience tests', () {
    test('Empty candidate feed throws FormatException to prevent starting broken TUN', () {
      const emptyFeed = '{"outbounds":[]}';
      expect(
        () => AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
          emptyFeed,
          groupId: 'min-latency',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('Malformed feed with no usable nodes throws FormatException safely', () {
      const malformedFeed = '{"outbounds":[{"tag":"broken-node"}]}';
      expect(
        () => AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
          malformedFeed,
          groupId: 'stable',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('Single direct node with tag direct omits detour: direct from DNS servers', () {
      const singleProxyFeed = '''{
        "outbounds": [
          {"tag": "node-1", "type": "vless", "server": "1.1.1.1", "server_port": 443}
        ]
      }''';
      final configJson = AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        singleProxyFeed,
        groupId: 'direct',
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>();

      for (final s in servers) {
        expect(s['detour'], isNot('direct'), reason: 'sing-box 1.13 rejects detour: direct on direct outbounds');
      }
    });

    test('Incompatible transports (xhttp, splithttp) are filtered out from candidates', () {
      const feedWithIncompat = '''{
        "outbounds": [
          {"tag": "node-xhttp", "type": "vless", "server": "1.1.1.1", "server_port": 443, "transport": {"type": "xhttp"}},
          {"tag": "node-splithttp", "type": "vless", "server": "1.1.1.2", "server_port": 443, "transport": {"type": "splithttp"}},
          {"tag": "node-ws", "type": "vless", "server": "1.1.1.3", "server_port": 443, "transport": {"type": "ws"}},
          {"tag": "node-tcp", "type": "vless", "server": "1.1.1.4", "server_port": 443}
        ]
      }''';

      final configJson = AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feedWithIncompat,
        groupId: 'min-latency',
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final outbounds = (config['outbounds'] as List<dynamic>).cast<Map<String, dynamic>>();
      final tags = outbounds.map((o) => o['tag'] as String).toList();

      expect(tags, isNot(contains('node-xhttp')));
      expect(tags, isNot(contains('node-splithttp')));
      expect(tags, contains('node-ws'));
      expect(tags, contains('node-tcp'));
    });

    test('Multi-tier DNS split is properly configured', () {
      const feed = '''{
        "outbounds": [
          {"tag": "node-ws", "type": "vless", "server": "1.1.1.3", "server_port": 443, "transport": {"type": "ws"}}
        ]
      }''';

      final configJson = AndroidMosaicAccountService.buildNativeTunConfigFromSubscriptionPayload(
        feed,
        groupId: 'min-latency',
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['strategy'], equals('prefer_ipv4'));

      final servers = (dns['servers'] as List<dynamic>).cast<Map<String, dynamic>>();
      final serverTags = servers.map((s) => s['tag']).toList();
      expect(serverTags, contains('dns-direct'));
      expect(serverTags, contains('dns-fallback'));
    });
  });
}
