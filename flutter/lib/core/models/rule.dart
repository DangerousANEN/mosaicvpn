/// Routing rule action.
enum RuleAction {
  proxy('proxy'),
  direct('direct'),
  block('block');

  final String value;
  const RuleAction(this.value);

  static RuleAction fromString(String s) => RuleAction.values
      .firstWhere((a) => a.value == s, orElse: () => RuleAction.proxy);
}

/// Match conditions for a routing rule.
class RuleMatch {
  final List<String> domainSuffix;
  final List<String> domain;
  final List<String> ipCIDR;
  final List<String> process;
  final List<String> geosite;
  final List<String> geoip;
  final int? port;

  const RuleMatch({
    this.domainSuffix = const [],
    this.domain = const [],
    this.ipCIDR = const [],
    this.process = const [],
    this.geosite = const [],
    this.geoip = const [],
    this.port,
  });

  factory RuleMatch.fromJson(Map<String, dynamic> j) => RuleMatch(
        domainSuffix: (j['domain_suffix'] as List?)?.cast<String>() ?? [],
        domain: (j['domain'] as List?)?.cast<String>() ?? [],
        ipCIDR: (j['ip_cidr'] as List?)?.cast<String>() ?? [],
        process: (j['process'] as List?)?.cast<String>() ?? [],
        geosite: (j['geosite'] as List?)?.cast<String>() ?? [],
        geoip: (j['geoip'] as List?)?.cast<String>() ?? [],
        port: j['port'],
      );

  String get summary {
    final parts = <String>[];
    if (domainSuffix.isNotEmpty) parts.add('suffix:${domainSuffix.join(",")}');
    if (domain.isNotEmpty) parts.add('domain:${domain.join(",")}');
    if (ipCIDR.isNotEmpty) parts.add('ip:${ipCIDR.join(",")}');
    if (process.isNotEmpty) parts.add('proc:${process.join(",")}');
    if (geosite.isNotEmpty) parts.add('geosite:${geosite.join(",")}');
    if (geoip.isNotEmpty) parts.add('geoip:${geoip.join(",")}');
    if (port != null) parts.add('port:$port');
    return parts.isEmpty ? 'no match conditions' : parts.join(' · ');
  }
}

/// Routing rule.
/// Matches Go: proto.Rule
class Rule {
  final String id;
  final String name;
  final RuleAction action;
  final RuleMatch match;
  final bool enabled;
  final int priority;

  const Rule({
    this.id = '',
    this.name = '',
    this.action = RuleAction.proxy,
    this.match = const RuleMatch(),
    this.enabled = true,
    this.priority = 0,
  });

  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        action: RuleAction.fromString(j['action'] ?? 'proxy'),
        match: j['match'] != null
            ? RuleMatch.fromJson(j['match'])
            : const RuleMatch(),
        enabled: j['enabled'] ?? true,
        priority: j['priority'] ?? 0,
      );
}
