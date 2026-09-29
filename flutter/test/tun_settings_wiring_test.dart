import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Proves the user-facing TUN settings actually reach the sing-box config.
///
/// Context: an audit of Preferences found 44 of 70 fields with no behavioural
/// reader outside the Settings screen. The interface reported MTU 1420 while the
/// live TUN came up at 9000, and stack was pinned to gvisor regardless of the
/// stored 'system' default. These tests pin the wiring so it cannot regress
/// silently again.
void main() {
  // The service holds these settings in process-wide state, so a test that
  // changes them must put them back or later tests inherit them (this actually
  // made test_adblock_test fail in a full-suite run while passing alone).
  tearDown(AndroidMosaicAccountService.resetTunSettings);

  const sampleShareUri =
      'vless://11111111-2222-3333-4444-555555555555@example.com:443'
      '?encryption=none&security=tls&sni=example.com&type=ws&path=%2F#node';

  Map<String, dynamic> buildAndDecode({TunSettings? settings}) {
    AndroidMosaicAccountService.tunSettings =
        settings ?? const TunSettings();
    final raw = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      sampleShareUri,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Map<String, dynamic> tunInbound(Map<String, dynamic> config) {
    final inbounds = (config['inbounds'] as List).cast<Map<String, dynamic>>();
    return inbounds.firstWhere((value) => value['type'] == 'tun');
  }

  group('MTU', () {
    test('the configured MTU lands in the config (not the library default)', () {
      final config = buildAndDecode(settings: const TunSettings(mtu: 1420));
      expect(tunInbound(config)['mtu'], 1420,
          reason: 'a missing mtu key is what let the interface come up at 9000');
    });

    test('an absurd MTU is clamped instead of trusted', () {
      final high = buildAndDecode(settings: const TunSettings(mtu: 9000));
      expect(tunInbound(high)['mtu'], 1500,
          reason: '9000 is accepted by the sing-box schema, so we must clamp');
      final low = buildAndDecode(settings: const TunSettings(mtu: 100));
      expect(tunInbound(low)['mtu'], 1280,
          reason: 'below 1280 breaks IPv6 and QUIC');
    });
  });

  group('TUN stack', () {
    test("the stored 'system' stack is honoured", () {
      final config = buildAndDecode(settings: const TunSettings(stack: 'system'));
      expect(tunInbound(config)['stack'], 'system',
          reason: 'this was hardcoded to gvisor while Preferences said system');
    });

    test('gvisor and mixed are passed through', () {
      for (final stack in ['gvisor', 'mixed']) {
        final config = buildAndDecode(settings: TunSettings(stack: stack));
        expect(tunInbound(config)['stack'], stack);
      }
    });

    test('an unknown stack falls back to system rather than crashing', () {
      final config = buildAndDecode(settings: const TunSettings(stack: 'nonsense'));
      expect(tunInbound(config)['stack'], 'system');
    });
  });

  group('IPv6', () {
    test('blocking IPv6 removes the v6 address from the interface', () {
      final withV6 = buildAndDecode(settings: const TunSettings());
      final withoutV6 =
          buildAndDecode(settings: const TunSettings(blockIPv6: true));
      final v6 = (tunInbound(withV6)['address'] as List)
          .where((a) => a.toString().contains(':'))
          .length;
      final v6Blocked = (tunInbound(withoutV6)['address'] as List)
          .where((a) => a.toString().contains(':'))
          .length;
      expect(v6, 1, reason: 'IPv6 present by default');
      expect(v6Blocked, 0, reason: 'the toggle must actually remove it');
    });
  });

  group('DNS', () {
    test('a user-selected resolver overrides the built-in default', () {
      final config = buildAndDecode(
          settings: const TunSettings(
              dnsDirect: '9.9.9.9', dnsProxied: '8.8.8.8'));
      final dns = config['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
      final byTag = {for (final s in servers) s['tag']: s['server']};
      expect(byTag['dns-direct'], '9.9.9.9');
      expect(byTag['dns-remote'], '8.8.8.8');
    });

    test('an empty resolver keeps the built-in default', () {
      final config = buildAndDecode(settings: const TunSettings());
      final dns = config['dns'] as Map<String, dynamic>;
      final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
      final byTag = {for (final s in servers) s['tag']: s['server']};
      expect(byTag['dns-direct'], isNotEmpty);
      expect(byTag['dns-remote'], isNotEmpty);
    });
  });
}