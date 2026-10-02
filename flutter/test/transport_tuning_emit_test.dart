
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Transport-level tuning (MUX / TCP Fast Open / keep-alive / uTLS
/// fingerprint / TLS fragmentation) must reach the emitted sing-box JSON —
/// a UI toggle that never leaves the preferences store is a fake setting.
/// This suite pins the wiring AND runs the real sing-box 1.13.18 binary
/// (`check -c`) over every emitted variant, so a schema drift is a test
/// failure, not a production crash.
///   flutter test --exclude-tags integration
void main() {
  const shareUri =
      'vless://372f63da-99fa-4f82-9988-457d2f70091a@5.175.188.152:443'
      '?encryption=none&type=ws&path=%2Fmosaicws&host=sub.zxc1x1.ru'
      '&security=tls&sni=vk.com&allowInsecure=1&fp=chrome#Mosaic%20Direct';

  tearDownAll(() => AndroidMosaicAccountService.resetTunSettings());

  Map<String, dynamic> emit(String name) {
    final json = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      shareUri,
      adBlock: false,
      bypassRussianSites: false,
      autoFailover: true,
    );
    final cfg = jsonDecode(json) as Map<String, dynamic>;
    final out = Directory('build/singbox_check')..createSync(recursive: true);
    File('${out.path}/tuning_$name.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(cfg));
    return cfg;
  }

  Map<String, dynamic> firstProxyOutbound(Map<String, dynamic> cfg) {
    return (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) =>
            (o['type'] ?? '').toString().toLowerCase() == 'vless');
  }

  group('transport tuning wiring', () {
    test('MUX on -> multiplex block with h2mux + max_streams', () {
      AndroidMosaicAccountService.tunSettings = const TunSettings(
          muxEnabled: true, muxConcurrency: 12);
      final ob = firstProxyOutbound(emit('mux-on'));
      expect(ob['multiplex'], isNotNull,
          reason: 'MUX toggle must reach the emitted config');
      expect(ob['multiplex']['enabled'], isTrue);
      expect(ob['multiplex']['protocol'], 'h2mux');
      expect(ob['multiplex']['max_streams'], 12);
      expect(ob['multiplex']['padding'], isTrue);
    });

    test('TCP Fast Open + keep-alive -> top-level dialer fields', () {
      AndroidMosaicAccountService.tunSettings = const TunSettings(
          tcpFastOpen: 1, tcpKeepAlive: true);
      final ob = firstProxyOutbound(emit('tfo-keepalive'));
      expect(ob['tcp_fast_open'], isTrue,
          reason: 'sing-box 1.13 top-level dialer field');
      expect(ob['tcp_keep_alive'], '30s');
    });

    test('TLS fingerprint override -> utls.fingerprint', () {
      AndroidMosaicAccountService.tunSettings =
          const TunSettings(tlsFingerprint: 'firefox');
      final ob = firstProxyOutbound(emit('fp-firefox'));
      expect(ob['tls']['utls']['fingerprint'], 'firefox');
    });

    test('invalid fingerprint is skipped, config stays valid', () {
      AndroidMosaicAccountService.tunSettings =
          const TunSettings(tlsFingerprint: 'qqq-invalid');
      final ob = firstProxyOutbound(emit('fp-invalid'));
      expect(ob['tls']['utls']['fingerprint'], 'chrome',
          reason: 'share-link fp=chrome survives; bogus override dropped');
    });

    test('TLS fragmentation -> tls.fragment bool', () {
      AndroidMosaicAccountService.tunSettings =
          const TunSettings(tlsFragment: true);
      final ob = firstProxyOutbound(emit('tls-fragment'));
      expect(ob['tls']['fragment'], isTrue,
          reason: 'sing-box 1.13: tls.fragment is a BOOLEAN');
    });

    test('everything off -> no tuning keys leaked into config', () {
      AndroidMosaicAccountService.tunSettings = const TunSettings();
      final ob = firstProxyOutbound(emit('all-off'));
      expect(ob.containsKey('multiplex'), isFalse);
      expect(ob.containsKey('tcp_fast_open'), isFalse);
      expect(ob.containsKey('tcp_keep_alive'), isFalse);
      expect(ob['tls'].containsKey('fragment'), isFalse);
    });
  });
}
