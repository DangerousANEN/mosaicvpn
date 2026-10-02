import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Regression: preferences store DNS as URIs ('udp://77.88.8.8',
/// 'https://1.1.1.1/dns-query'). Emitting the URI string directly into
/// dns.servers[].server makes sing-box 1.13 fail at startup with
/// "missing domain resolver for domain server address" — the exact error
/// observed on a real device connect. The emitter must normalize.
void main() {
  const shareUri =
      'vless://372f63da-99fa-4f82-9988-457d2f70091a@5.175.188.152:443'
      '?encryption=none&type=ws&path=%2Fmosaicws&host=sub.zxc1x1.ru'
      '&security=tls&sni=vk.com&allowInsecure=1&fp=chrome#Mosaic%20Direct';

  tearDownAll(() => AndroidMosaicAccountService.resetTunSettings());

  Map<String, dynamic> serversOf(String json) {
    final cfg = jsonDecode(json) as Map<String, dynamic>;
    return {
      for (final s in (cfg['dns']['servers'] as List))
        (s as Map)['tag'] as String: s,
    };
  }

  test('URI-shaped dnsDirect/dnsProxied normalize to typed servers', () {
    AndroidMosaicAccountService.tunSettings = const TunSettings(
      dnsDirect: 'udp://77.88.8.8',
      dnsProxied: 'https://1.1.1.1/dns-query',
    );
    final servers = serversOf(
        AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      shareUri,
      adBlock: false,
      bypassRussianSites: false,
      autoFailover: true,
    ));
    final direct = servers['dns-direct'] as Map<String, dynamic>;
    expect(direct['type'], 'udp');
    expect(direct['server'], '77.88.8.8');
    expect(direct['server'], isNot(contains('://')),
        reason: 'URI must not leak into the server field');
    final remote = servers['dns-remote'] as Map<String, dynamic>;
    expect(remote['type'], 'https');
    expect(remote['server'], '1.1.1.1');
    expect(remote['server_port'], 443);
    expect(remote['path'], '/dns-query');
    expect(remote['detour'], 'Mosaic Direct');
  });

  test('bare IP and DoT forms stay valid', () {
    AndroidMosaicAccountService.tunSettings = const TunSettings(
      dnsDirect: '94.140.14.14',
      dnsProxied: 'tls://dns.adguard.com',
    );
    final servers = serversOf(
        AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      shareUri,
      adBlock: false,
      bypassRussianSites: false,
      autoFailover: true,
    ));
    final direct = servers['dns-direct'] as Map<String, dynamic>;
    expect(direct['type'], 'udp');
    expect(direct['server'], '94.140.14.14');
    final remote = servers['dns-remote'] as Map<String, dynamic>;
    expect(remote['type'], 'tls');
    expect(remote['server_port'], 853);
    expect((remote['tls'] as Map)['server_name'], 'dns.adguard.com');
  });
}
