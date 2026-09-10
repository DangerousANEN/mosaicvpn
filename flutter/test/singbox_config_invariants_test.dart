import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Structural invariants for the generated sing-box config.
///
/// These are deliberately assertions about *shape*, not byte-for-byte goldens:
/// a byte golden would fail on every harmless field reorder and get blessed
/// without reading, which is exactly how a stale golden hid a regression before.
/// Each rule below encodes a specific way we have actually shipped a broken
/// config to users.
void main() {
  const shareUri =
      'vless://372f63da-99fa-4f82-9988-457d2f70091a@example.invalid:443'
      '?encryption=none&type=ws&path=%2Fmosaicws&host=example.invalid'
      '&security=tls&sni=example.invalid&fp=chrome#Test%20Route';

  Map<String, dynamic> build({
    bool adBlock = false,
    bool bypassRussianSites = false,
  }) {
    final raw = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      shareUri,
      adBlock: adBlock,
      bypassRussianSites: bypassRussianSites,
      autoFailover: true,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  final permutations = <String, Map<String, dynamic>>{
    'plain': build(),
    'adblock': build(adBlock: true),
    'bypass_ru': build(bypassRussianSites: true),
    'adblock+bypass_ru': build(adBlock: true, bypassRussianSites: true),
  };

  permutations.forEach((label, config) {
    group('generated config [$label]', () {
      test('carries no legacy DNS server address', () {
        // sing-box 1.12 removed string-address DNS servers. Shipping one made
        // the core refuse the whole config and the app crashed on connect,
        // which read to users as "the VPN is broken".
        final servers = (config['dns']?['servers'] as List?) ?? const [];
        for (final server in servers.cast<Map<String, dynamic>>()) {
          expect(server.containsKey('address'), isFalse,
              reason: 'legacy "address" field removed in sing-box 1.12+; '
                  'offending server: $server');
          expect(server['type'], isNotNull,
              reason: 'every DNS server must declare an explicit type');
        }
      });

      test('never enables multiplex', () {
        // Measured against production: sing-box multiplex speaks a protocol
        // Xray peers do not, so the tunnel starts, validates, and silently
        // drops every stream. It must not appear in a generated config.
        final encoded = jsonEncode(config);
        expect(encoded.contains('"multiplex"'), isFalse,
            reason: 'multiplex black-holes traffic against our Xray servers');
      });

      test('does not use removed transports', () {
        // xhttp/splithttp are Xray-only; sing-box cannot dial them.
        final encoded = jsonEncode(config);
        for (final banned in ['"xhttp"', '"splithttp"']) {
          expect(encoded.contains(banned), isFalse,
              reason: '$banned is not supported by the sing-box core');
        }
      });

      test('keeps urltest groups from dropping live sessions', () {
        final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
        for (final ob in outbounds.where((o) => o['type'] == 'urltest')) {
          expect(ob['interrupt_exist_connections'], isFalse,
              reason: 'a urltest switch must not kill established sessions');
        }
      });

      test('has a well-formed inbound and at least one outbound', () {
        expect(config['inbounds'], isA<List>());
        expect((config['inbounds'] as List), isNotEmpty);
        expect((config['outbounds'] as List), isNotEmpty);
      });
    });
  });

  test('adblock is expressed as a rule action, not a fake server', () {
    final config = build(adBlock: true);
    final rules = (config['dns']?['rules'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final blocking = rules.where((r) => r['action'] == 'predefined').toList();

    expect(blocking, isNotEmpty,
        reason: 'ad blocking must use the native predefined-rule action');
    expect(blocking.first['rcode'], 'NOERROR');
  });

  test('adblock off means no blocking rule at all', () {
    final config = build();
    final rules = (config['dns']?['rules'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    expect(rules.where((r) => r['action'] == 'predefined'), isEmpty,
        reason: 'disabled ad blocking must not leave a blocking rule behind');
  });
}
