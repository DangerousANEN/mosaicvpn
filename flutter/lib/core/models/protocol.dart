/// Protocol identifiers supported by MosaicBox.
/// Matches Go: internal/proto/types.go Protocol, extended with newer
/// sing-box / xray-only protocols for the manual add wizard.
///
/// Categories (used by the Add Server wizard UI):
///  - xrayCore:        vless, vmess, trojan, shadowsocks, shadowsocksR,
///                     shadowsocks2022, shadowTLS, anyTLS, naive, wireguard
///  - sing-box only:   hysteria2, tuic, juicity, mieru, http3, trustTunnel
///  - basic tunnel:    socks, http, ssh, chain (custom)
enum Protocol {
  vless('vless'),
  vmess('vmess'),
  trojan('trojan'),
  shadowsocks('shadowsocks'),
  shadowsocksR('shadowsocksr'), // SSR
  shadowsocks2022('shadowsocks-2022'), // SS2022
  shadowTLS('shadowtls'),
  anyTLS('anytls'),
  hysteria2('hysteria2'),
  tuic('tuic'),
  juicity('juicity'),
  naive('naive'),
  mieru('mieru'),
  amneziaWG('amneziawg'),
  wireguard('wireguard'),
  http3('http3'), // HTTP/3 (QUIC-based proxy, sing-box)
  trustTunnel('trusttunnel'), // TrustTunnel (sing-box)
  socks('socks'),
  http('http'),
  ssh('ssh'),
  custom('custom'),
  chain('chain');

  final String value;
  const Protocol(this.value);

  static Protocol fromString(String s) {
    final v = s.toLowerCase();
    return Protocol.values
        .firstWhere((p) => p.value == v, orElse: () => Protocol.custom);
  }

  static List<Protocol> get all => Protocol.values;

  /// Human-readable display name.
  String get displayName {
    switch (this) {
      case Protocol.shadowsocks:
        return 'Shadowsocks';
      case Protocol.shadowsocksR:
        return 'ShadowsocksR';
      case Protocol.shadowsocks2022:
        return 'Shadowsocks 2022';
      case Protocol.shadowTLS:
        return 'ShadowTLS';
      case Protocol.anyTLS:
        return 'AnyTLS';
      case Protocol.vless:
        return 'VLESS';
      case Protocol.vmess:
        return 'VMess';
      case Protocol.trojan:
        return 'Trojan';
      case Protocol.hysteria2:
        return 'Hysteria2';
      case Protocol.tuic:
        return 'TUIC';
      case Protocol.juicity:
        return 'Juicity';
      case Protocol.naive:
        return 'NaiveProxy';
      case Protocol.mieru:
        return 'Mieru';
      case Protocol.amneziaWG:
        return 'AmneziaWG';
      case Protocol.wireguard:
        return 'WireGuard';
      case Protocol.http3:
        return 'HTTP/3';
      case Protocol.trustTunnel:
        return 'TrustTunnel';
      case Protocol.socks:
        return 'SOCKS';
      case Protocol.http:
        return 'HTTP';
      case Protocol.ssh:
        return 'SSH';
      case Protocol.custom:
        return 'Custom';
      case Protocol.chain:
        return 'Chain';
    }
  }

  /// URI scheme used for share-links / clipboard import (e.g. `vless://...`).
  String get uriScheme {
    switch (this) {
      case Protocol.vless:
        return 'vless';
      case Protocol.vmess:
        return 'vmess';
      case Protocol.trojan:
        return 'trojan';
      case Protocol.shadowsocks:
        return 'ss';
      case Protocol.shadowsocksR:
        return 'ssr';
      case Protocol.shadowsocks2022:
        return 'ss2022';
      case Protocol.shadowTLS:
        return 'shadowtls';
      case Protocol.anyTLS:
        return 'anytls';
      case Protocol.hysteria2:
        return 'hysteria2';
      case Protocol.tuic:
        return 'tuic';
      case Protocol.juicity:
        return 'juicity';
      case Protocol.naive:
        return 'naive+https';
      case Protocol.mieru:
        return 'mieru';
      case Protocol.wireguard:
        return 'wireguard';
      case Protocol.amneziaWG:
        return 'amneziawg';
      case Protocol.http3:
        return 'http3';
      case Protocol.trustTunnel:
        return 'trusttunnel';
      case Protocol.socks:
        return 'socks';
      case Protocol.http:
        return 'http';
      case Protocol.ssh:
        return 'ssh';
      case Protocol.custom:
        return 'custom';
      case Protocol.chain:
        return 'chain';
    }
  }
}
