/// Cloudflare WARP configuration.
/// Matches Go: proto.WARPConfig
class WARPConfig {
  final bool enabled;
  final String mode; // "warp" | "warp+"
  final String licenseKey; // WARP+ key
  final String teamToken; // Zero Trust team token
  final String bindAddr; // local:port for the warp outbound

  WARPConfig({
    this.enabled = false,
    this.mode = 'warp',
    this.licenseKey = '',
    this.teamToken = '',
    this.bindAddr = '',
  });

  factory WARPConfig.fromJson(Map<String, dynamic> j) => WARPConfig(
        enabled: j['enabled'] ?? false,
        mode: j['mode'] ?? 'warp',
        licenseKey: j['license_key'] ?? '',
        teamToken: j['team_token'] ?? '',
        bindAddr: j['bind_addr'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'mode': mode,
        'license_key': licenseKey,
        'team_token': teamToken,
        'bind_addr': bindAddr,
      };
}
