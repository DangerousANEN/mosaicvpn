/// DNS resolution strategy for the tunnel.
/// Matches Go: proto.DNSConfig
class DNSConfig {
  final String mode; // "fake-ip" | "real-ip" | "disabled"
  final String proxied; // upstream DNS for proxy traffic
  final String direct; // upstream DNS for direct traffic
  final String fakeIPRange; // CIDR for fake-ip allocation

  const DNSConfig({
    this.mode = 'fake-ip',
    this.proxied = 'https://1.1.1.1/dns-query',
    this.direct = 'udp://77.88.8.8',
    this.fakeIPRange = '198.18.0.0/15',
  });

  factory DNSConfig.fromJson(Map<String, dynamic> j) => DNSConfig(
        mode: j['mode'] ?? 'fake-ip',
        proxied: j['proxied'] ?? '',
        direct: j['direct'] ?? '',
        fakeIPRange: j['fake_ip_range'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'mode': mode,
        'proxied': proxied,
        'direct': direct,
        'fake_ip_range': fakeIPRange,
      };

  static DNSConfig get defaults => DNSConfig();
}
