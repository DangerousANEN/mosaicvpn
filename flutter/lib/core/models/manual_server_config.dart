import 'protocol.dart';

/// Manual server configuration — used by the "Add Server" wizard.
/// Holds protocol-specific fields for every protocol we support.
/// The wizard fills this in step-by-step, then a `toServer()` / `toUri()`
/// helper converts it into a share-link or a Go daemon JSON object.
class ManualServerConfig {
  // Common
  Protocol protocol;
  String name; // user-friendly label, optional
  String address;
  int port;

  // VLESS / VMess / Trojan / NaiveProxy
  String uuid; // or password for trojan
  String flow; // vless flow (xtls-rprx-vision etc.)
  String encryption; // vmess: auto/none/aes-128-gcm
  String network; // tcp/ws/grpc/h2/httpupgrade/xhttp
  String path; // ws path, grpc serviceName, h2 path
  String hostHeader; // ws Host, grpc authority, h2 host
  String sni; // TLS SNI
  String alpn; // h2/http/1.1
  bool tls; // TLS on/off for vmess
  bool allowInsecure; // skip cert verification
  String fingerprint; // utls fingerprint: chrome/firefox/safari/random

  // Shadowsocks / SS2022
  String
      ssMethod; // aes-256-gcm, chacha20-ietf-poly1305, 2022-blake3-aes-128-gcm, etc.
  String ssPassword;
  String ssPlugin; // obfslocal/tls etc. (SS only)
  String ssPluginOpts;

  // ShadowsocksR
  String ssrMethod; // aes-256-cfb etc.
  String ssrPassword;
  String ssrObfs; // plain/http_simple/tls1.2_ticket_auth
  String ssrProtocol; // origin/auth_sha1_v4/auth_aes128_md5
  String ssrProtocolParam;

  // ShadowTLS
  int shadowTlsVersion; // 2 or 3
  String shadowTlsPassword;

  // AnyTLS
  String anytlsPassword;
  String anytlsFingerprint;

  // Hysteria2 / TUIC / Juicity
  String auth; // auth password / auth id:password
  String obfs; // salamander obfs for hysteria2
  String obfsPassword;
  int upMbps; // 0 = unlimited
  int downMbps;
  int congestionControl; // 0=bbr, 1=cubic, 2=new_reno (TUIC)
  int udpRelayMode; // 0=native, 1=quic (TUIC)
  bool zeroRttHandshake;
  bool heartbeat;

  // Mieru
  int mieruPortAlpnmapped; // 0 = auto

  // WireGuard / AmneziaWG
  String wgPrivateKey;
  String wgPeerPublicKey;
  String wgPreSharedKey;
  String wgEndpoint;
  int wgMtu;

  // HTTP/3 / TrustTunnel
  String http3User;
  String http3Password;
  String trustTlsSni;

  // SOCKS / HTTP
  String socksUser;
  String socksPassword;

  // SSH
  String sshUser;
  String sshPassword;
  String sshPrivateKey; // base64 of OpenSSH key

  ManualServerConfig({
    this.protocol = Protocol.vless,
    this.name = '',
    this.address = '',
    this.port = 443,
    this.uuid = '',
    this.flow = '',
    this.encryption = 'auto',
    this.network = 'tcp',
    this.path = '',
    this.hostHeader = '',
    this.sni = '',
    this.alpn = '',
    this.tls = true,
    this.allowInsecure = false,
    this.fingerprint = 'chrome',
    this.ssMethod = 'aes-256-gcm',
    this.ssPassword = '',
    this.ssPlugin = '',
    this.ssPluginOpts = '',
    this.ssrMethod = 'aes-256-cfb',
    this.ssrPassword = '',
    this.ssrObfs = 'plain',
    this.ssrProtocol = 'origin',
    this.ssrProtocolParam = '',
    this.shadowTlsVersion = 3,
    this.shadowTlsPassword = '',
    this.anytlsPassword = '',
    this.anytlsFingerprint = 'chrome',
    this.auth = '',
    this.obfs = '',
    this.obfsPassword = '',
    this.upMbps = 0,
    this.downMbps = 0,
    this.congestionControl = 0,
    this.udpRelayMode = 0,
    this.zeroRttHandshake = false,
    this.heartbeat = false,
    this.mieruPortAlpnmapped = 0,
    this.wgPrivateKey = '',
    this.wgPeerPublicKey = '',
    this.wgPreSharedKey = '',
    this.wgEndpoint = '',
    this.wgMtu = 1280,
    this.http3User = '',
    this.http3Password = '',
    this.trustTlsSni = '',
    this.socksUser = '',
    this.socksPassword = '',
    this.sshUser = '',
    this.sshPassword = '',
    this.sshPrivateKey = '',
  });

  /// Build a URI share-link for this config (vless://, ss://, hysteria2://, …).
  /// Returns `null` if the protocol doesn't have a standard URI format.
  String? toUri() {
    final p = protocol;
    switch (p) {
      case Protocol.vless:
        // vless://uuid@host:port?encryption=...&security=tls&type=ws&path=...&host=...&sni=...&fp=...&flow=...#name
        final params = <String>[];
        if (encryption.isNotEmpty) params.add('encryption=$encryption');
        params.add('security=${tls ? 'tls' : 'none'}');
        params.add('type=$network');
        if (path.isNotEmpty) params.add('path=${Uri.encodeComponent(path)}');
        if (hostHeader.isNotEmpty) {
          params.add('host=${Uri.encodeComponent(hostHeader)}');
        }
        if (sni.isNotEmpty) params.add('sni=$sni');
        if (alpn.isNotEmpty) params.add('alpn=$alpn');
        if (tls && fingerprint.isNotEmpty) params.add('fp=$fingerprint');
        if (flow.isNotEmpty) params.add('flow=$flow');
        if (allowInsecure) params.add('allowInsecure=1');
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'vless://$uuid@$address:$port?${params.join('&')}$frag';

      case Protocol.vmess:
        // vmess://base64(json)
        final cfg = {
          'v': '2',
          'ps': name,
          'add': address,
          'port': '$port',
          'id': uuid,
          'aid': '0',
          'net': network,
          'path': path,
          'host': hostHeader,
          'tls': tls ? 'tls' : '',
          'sni': sni,
          'alpn': alpn,
          'fp': fingerprint,
          'scy': encryption,
        };
        final json = _encodeVmessJson(cfg);
        return 'vmess://${_base64UrlEncode(json.toString())}';

      case Protocol.trojan:
        final params = <String>[];
        params.add('type=$network');
        if (path.isNotEmpty) params.add('path=${Uri.encodeComponent(path)}');
        if (hostHeader.isNotEmpty) {
          params.add('host=${Uri.encodeComponent(hostHeader)}');
        }
        if (sni.isNotEmpty) params.add('sni=$sni');
        if (alpn.isNotEmpty) params.add('alpn=$alpn');
        if (fingerprint.isNotEmpty) params.add('fp=$fingerprint');
        if (flow.isNotEmpty) params.add('flow=$flow');
        if (allowInsecure) params.add('allowInsecure=1');
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'trojan://$uuid@$address:$port?${params.join('&')}$frag';

      case Protocol.shadowsocks:
        // ss://base64url(method:password)@host:port#name
        final userInfo = '$ssMethod:$ssPassword';
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'ss://${_base64UrlEncode(userInfo)}@$address:$port$frag';

      case Protocol.shadowsocksR:
        final base = '$ssrMethod:$ssrPassword';
        final user = _base64UrlEncode(base);
        final params = <String>[];
        params.add('obfs=$ssrObfs');
        params.add('protocol=$ssrProtocol');
        if (ssrProtocolParam.isNotEmpty) {
          params.add('protocol_param=${Uri.encodeComponent(ssrProtocolParam)}');
        }
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'ssr://$user@$address:$port?${params.join('&')}$frag';

      case Protocol.shadowsocks2022:
        // ss2022://base64url(method:password)@host:port#name
        final userInfo = '$ssMethod:$ssPassword';
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'ss2022://${_base64UrlEncode(userInfo)}@$address:$port$frag';

      case Protocol.shadowTLS:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'shadowtls://$shadowTlsPassword@$address:$port?v=$shadowTlsVersion&sni=$sni$frag';

      case Protocol.anyTLS:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'anytls://$anytlsPassword@$address:$port?sni=$sni&fp=$anytlsFingerprint$frag';

      case Protocol.hysteria2:
        final params = <String>[];
        if (sni.isNotEmpty) params.add('sni=$sni');
        if (alpn.isNotEmpty) params.add('alpn=$alpn');
        if (obfs.isNotEmpty) params.add('obfs=$obfs');
        if (obfsPassword.isNotEmpty) {
          params.add('obfs-password=${Uri.encodeComponent(obfsPassword)}');
        }
        if (auth.isNotEmpty) params.add('auth=${Uri.encodeComponent(auth)}');
        if (upMbps > 0) params.add('up=$upMbps');
        if (downMbps > 0) params.add('down=$downMbps');
        if (allowInsecure) params.add('insecure=1');
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'hysteria2://$auth@$address:$port?${params.join('&')}$frag';

      case Protocol.tuic:
        final params = <String>[];
        if (sni.isNotEmpty) params.add('sni=$sni');
        if (alpn.isNotEmpty) params.add('alpn=$alpn');
        params.add('congestion_control=${_tuicCongestion(congestionControl)}');
        params.add('udp_relay_mode=${udpRelayMode == 0 ? 'native' : 'quic'}');
        if (zeroRttHandshake) params.add('zero_rtt_handshake=1');
        if (allowInsecure) params.add('allow_insecure=1');
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'tuic://$auth@$address:$port?${params.join('&')}$frag';

      case Protocol.juicity:
        final params = <String>[];
        if (sni.isNotEmpty) params.add('sni=$sni');
        if (allowInsecure) params.add('allow_insecure=1');
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'juicity://$auth@$address:$port?${params.join('&')}$frag';

      case Protocol.naive:
        final authPair =
            '${Uri.encodeComponent(http3User.isEmpty ? 'user' : http3User)}:${Uri.encodeComponent(http3Password)}';
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'naive+https://$authPair@$address:$port?sni=$sni$frag';

      case Protocol.mieru:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'mieru://$auth@$address:$port$frag';

      case Protocol.wireguard:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        return 'wireguard://${Uri.encodeComponent(wgPrivateKey)}@$address:$port?peer=$wgPeerPublicKey&endpoint=$wgEndpoint&mtu=$wgMtu$frag';

      case Protocol.socks:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        if (socksUser.isEmpty && socksPassword.isEmpty) {
          return 'socks://$address:$port$frag';
        }
        return 'socks://${Uri.encodeComponent(socksUser)}:${Uri.encodeComponent(socksPassword)}@$address:$port$frag';

      case Protocol.http:
        final frag = name.isNotEmpty ? '#${Uri.encodeComponent(name)}' : '';
        if (http3User.isEmpty && http3Password.isEmpty) {
          return 'http://$address:$port$frag';
        }
        return 'http://${Uri.encodeComponent(http3User)}:${Uri.encodeComponent(http3Password)}@$address:$port$frag';

      case Protocol.amneziaWG:
      case Protocol.http3:
      case Protocol.trustTunnel:
      case Protocol.ssh:
      case Protocol.custom:
      case Protocol.chain:
        return null; // no universally-agreed URI scheme
    }
  }

  /// Returns `true` if the minimum required fields for this protocol are set.
  bool get isValid {
    if (address.trim().isEmpty || port <= 0 || port > 65535) return false;
    switch (protocol) {
      case Protocol.vless:
      case Protocol.vmess:
        return uuid.trim().isNotEmpty;
      case Protocol.trojan:
        return uuid.trim().isNotEmpty;
      case Protocol.shadowsocks:
      case Protocol.shadowsocks2022:
        return ssMethod.isNotEmpty && ssPassword.isNotEmpty;
      case Protocol.shadowsocksR:
        return ssrMethod.isNotEmpty && ssrPassword.isNotEmpty;
      case Protocol.shadowTLS:
        return shadowTlsPassword.isNotEmpty;
      case Protocol.anyTLS:
        return anytlsPassword.isNotEmpty;
      case Protocol.hysteria2:
      case Protocol.tuic:
      case Protocol.juicity:
        return auth.isNotEmpty;
      case Protocol.naive:
        return http3User.isNotEmpty && http3Password.isNotEmpty;
      case Protocol.mieru:
        return auth.isNotEmpty;
      case Protocol.wireguard:
      case Protocol.amneziaWG:
        return wgPrivateKey.isNotEmpty && wgPeerPublicKey.isNotEmpty;
      case Protocol.http3:
        return http3User.isNotEmpty && http3Password.isNotEmpty;
      case Protocol.trustTunnel:
        return anytlsPassword.isNotEmpty;
      case Protocol.socks:
      case Protocol.http:
        return true; // auth optional
      case Protocol.ssh:
        return sshUser.isNotEmpty &&
            (sshPassword.isNotEmpty || sshPrivateKey.isNotEmpty);
      case Protocol.custom:
      case Protocol.chain:
        return false;
    }
  }

  String _tuicCongestion(int i) {
    switch (i) {
      case 1:
        return 'cubic';
      case 2:
        return 'new_reno';
      default:
        return 'bbr';
    }
  }

  static String _base64UrlEncode(String input) {
    final bytes = Uri.encodeFull(input).codeUnits;
    // Simple base64url without padding using base64 then +/ -> -_
    final b64 = _base64Encode(bytes);
    return b64.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }

  static String _base64Encode(List<int> bytes) {
    final alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i += 3) {
      final b0 = bytes[i];
      final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      sb.write(alphabet[b0 >> 2]);
      sb.write(alphabet[((b0 & 3) << 4) | (b1 >> 4)]);
      if (i + 1 < bytes.length) {
        sb.write(alphabet[((b1 & 15) << 2) | (b2 >> 6)]);
      } else {
        sb.write('=');
      }
      if (i + 2 < bytes.length) {
        sb.write(alphabet[b2 & 63]);
      } else {
        sb.write('=');
      }
    }
    return sb.toString();
  }

  /// Build the VMess JSON body for `vmess://base64(json)` share-links.
  StringBuffer _encodeVmessJson(Map<String, String?> cfg) {
    final sb = StringBuffer('{');
    var first = true;
    for (final entry in cfg.entries) {
      if (entry.value == null || entry.value!.isEmpty) continue;
      if (!first) sb.write(',');
      sb.write('"${entry.key}":"${_escapeJson(entry.value!)}"');
      first = false;
    }
    sb.write('}');
    return sb;
  }

  String _escapeJson(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
