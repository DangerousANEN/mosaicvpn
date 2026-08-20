/// ProviderProfile — provider-defined UI/branding/billing/services manifest section.
/// Matches Go: proto.ProviderProfile
library;

/// Top-level provider manifest returned by GET /v1/manifest.
class ProviderManifest {
  final String providerName;
  final String userTier;
  final List<ManifestGroup> groups;
  final List<ManifestGroup> directRoutes;
  final ProviderProfile? profile;

  ProviderManifest({
    required this.providerName,
    this.userTier = 'free',
    this.groups = const [],
    this.directRoutes = const [],
    this.profile,
  });

  /// All user-visible virtual routes. Source pool nodes are not included.
  List<ManifestGroup> get routes => [...groups, ...directRoutes];

  factory ProviderManifest.fromJson(Map<String, dynamic> j) {
    return ProviderManifest(
      providerName: (j['provider_name'] ?? '').toString(),
      userTier: (j['user_tier'] ?? 'free').toString(),
      groups: (j['groups'] as List?)
              ?.map((g) => ManifestGroup.fromJson(g as Map<String, dynamic>))
              .toList() ??
          const [],
      directRoutes: (j['direct_routes'] as List?)
              ?.map((g) => ManifestGroup.fromJson(g as Map<String, dynamic>))
              .toList() ??
          const [],
      profile: j['profile'] != null
          ? ProviderProfile.fromJson(j['profile'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// A node entry inside a manifest group pool.
class ManifestNode {
  final String id;
  final int weight;
  final int priority;

  const ManifestNode({
    required this.id,
    this.weight = 1,
    this.priority = 0,
  });

  factory ManifestNode.fromJson(Map<String, dynamic> j) => ManifestNode(
        id: (j['id'] ?? '').toString(),
        weight: (j['weight'] ?? 1) as int,
        priority: (j['priority'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'weight': weight,
        'priority': priority,
      };
}

/// Provider-configurable, bounded HTTPS throughput probe settings.
class SpeedProbePolicy {
  final bool enabled;
  final List<String> downloadUrls;
  final String uploadUrl;
  final int sampleBytes;
  final int timeoutSeconds;
  final int maxCandidates;
  final double targetMbps;

  const SpeedProbePolicy({
    this.enabled = false,
    this.downloadUrls = const [],
    this.uploadUrl = '',
    this.sampleBytes = 2 * 1024 * 1024,
    this.timeoutSeconds = 12,
    this.maxCandidates = 2,
    this.targetMbps = 50,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'download_urls': downloadUrls,
        'upload_url': uploadUrl,
        'sample_bytes': sampleBytes,
        'timeout_seconds': timeoutSeconds,
        'max_candidates': maxCandidates,
        'target_mbps': targetMbps,
      };

  factory SpeedProbePolicy.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    int boundedInt(String key, int fallback, int min, int max) =>
        (((value[key] as num?)?.toInt() ?? fallback).clamp(min, max)).toInt();
    final urls = (value['download_urls'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.startsWith('https://'))
            .take(3)
            .toList(growable: false) ??
        const <String>[];
    final target = (value['target_mbps'] as num?)?.toDouble() ?? 50;
    return SpeedProbePolicy(
      enabled: value['enabled'] == true,
      downloadUrls: urls,
      uploadUrl: value['upload_url']?.toString() ?? '',
      sampleBytes: boundedInt(
          'sample_bytes', 2 * 1024 * 1024, 256 * 1024, 8 * 1024 * 1024),
      timeoutSeconds: boundedInt('timeout_seconds', 12, 3, 30),
      maxCandidates: boundedInt('max_candidates', 2, 1, 3),
      targetMbps: target.clamp(1, 1000).toDouble(),
    );
  }
}

/// Server-defined bounded selection policy executed by the generic client.
/// New policy modes and weights can be supplied without a client release.
class ManifestClientPolicy {
  final String mode;
  final int shardSize;
  final int maxParallelProbes;
  final int probeTtlSeconds;
  final int maxFailoverTries;
  final double latencyWeight;
  final double lossWeight;
  final double stabilityWeight;
  final double speedWeight;
  final SpeedProbePolicy speedProbe;

  const ManifestClientPolicy({
    this.mode = 'latency',
    this.shardSize = 16,
    this.maxParallelProbes = 4,
    this.probeTtlSeconds = 600,
    this.maxFailoverTries = 3,
    this.latencyWeight = .45,
    this.lossWeight = .30,
    this.stabilityWeight = .25,
    this.speedWeight = 0,
    this.speedProbe = const SpeedProbePolicy(),
  });

  factory ManifestClientPolicy.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    int boundedInt(String key, int fallback, int min, int max) {
      final number = (value[key] as num?)?.toInt() ?? fallback;
      return number.clamp(min, max);
    }

    return ManifestClientPolicy(
      mode: value['mode']?.toString() ?? 'latency',
      shardSize: boundedInt('shard_size', 16, 1, 32),
      maxParallelProbes: boundedInt('max_parallel_probes', 4, 1, 8),
      probeTtlSeconds: boundedInt('probe_ttl_seconds', 600, 30, 3600),
      maxFailoverTries: boundedInt('max_failover_tries', 3, 1, 8),
      latencyWeight: (value['latency_weight'] as num?)?.toDouble() ?? .45,
      lossWeight: (value['loss_weight'] as num?)?.toDouble() ?? .30,
      stabilityWeight: (value['stability_weight'] as num?)?.toDouble() ?? .25,
      speedWeight: (value['speed_weight'] as num?)?.toDouble() ?? 0,
      speedProbe: SpeedProbePolicy.fromJson(
          value['speed_probe'] as Map<String, dynamic>?),
    );
  }
}

/// A server-defined Smart Group. Its concrete name, policy and source pool
/// come entirely from the provider manifest; the generic app knows no fixed IDs.
class ManifestGroup {
  final String id;
  final String title;

  /// Generic provider route type, such as `smart_group`.
  final String routeType;

  /// Backend selection strategy, such as urltest or fallback.
  final String type;
  final String poolId;
  final String countryCode;
  final String protocol;
  final String userTier;
  final String badge;
  final String category;
  final String icon;
  final String description;
  final bool disabled;
  final String disabledReason;
  final ManifestClientPolicy clientPolicy;
  final List<ManifestNode> nodes;
  final int pingInterval;
  final int maxRetries;
  final int failoverDelay;

  ManifestGroup({
    required this.id,
    required this.title,
    this.routeType = 'smart_group',
    this.type = 'urltest',
    this.poolId = '',
    this.countryCode = '',
    this.protocol = '',
    this.userTier = 'free',
    this.badge = '',
    this.category = '',
    this.icon = '',
    this.description = '',
    this.disabled = false,
    this.disabledReason = '',
    this.clientPolicy = const ManifestClientPolicy(),
    this.nodes = const [],
    this.pingInterval = 30,
    this.maxRetries = 3,
    this.failoverDelay = 5,
  });

  factory ManifestGroup.fromJson(Map<String, dynamic> j) {
    return ManifestGroup(
      id: (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      routeType: (j['route_type'] ?? 'smart_group').toString(),
      type: (j['type'] ?? 'urltest').toString(),
      poolId: (j['pool_id'] ?? '').toString(),
      countryCode: (j['country_code'] ?? '').toString().toUpperCase(),
      protocol: (j['protocol'] ?? '').toString(),
      userTier: (j['user_tier'] ?? 'free').toString(),
      badge: (j['badge'] ?? '').toString(),
      category: (j['category'] ?? '').toString(),
      icon: (j['icon'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      disabled: j['disabled'] == true,
      disabledReason: (j['disabled_reason'] ?? '').toString(),
      clientPolicy: ManifestClientPolicy.fromJson(
          j['client_policy'] as Map<String, dynamic>?),
      nodes: (j['nodes'] as List?)
              ?.map((n) => ManifestNode.fromJson(n as Map<String, dynamic>))
              .toList() ??
          const [],
      pingInterval: (j['ping_interval'] ?? 30) as int,
      maxRetries: (j['max_retries'] ?? 3) as int,
      failoverDelay: (j['failover_delay'] ?? 5) as int,
    );
  }

  /// Generic transport strategy label. The display title and policy remain
  /// provider-owned rather than inferred from a client-side group ID.
  String get strategyLabel => type;
}

/// Health status of a single node, returned by the pool engine.
class NodeHealth {
  final String nodeId;
  final bool alive;
  final int latencyMs;
  final String? error;

  const NodeHealth({
    required this.nodeId,
    this.alive = false,
    this.latencyMs = 0,
    this.error,
  });

  factory NodeHealth.fromJson(Map<String, dynamic> j) => NodeHealth(
        nodeId: (j['node_id'] ?? '').toString(),
        alive: (j['alive'] ?? false) as bool,
        latencyMs: (j['latency_ms'] ?? 0) as int,
        error: j['error']?.toString(),
      );

  bool get isUnknown => !alive && error == null && latencyMs == 0;
}

/// Provider-defined profile section (branding, billing, services, widgets).
class ProviderProfile {
  final ProviderBranding branding;
  final ProviderBilling? billing;
  final List<ProviderService> services;
  final List<ProviderWidget> widgets;

  ProviderProfile({
    required this.branding,
    this.billing,
    this.services = const [],
    this.widgets = const [],
  });

  factory ProviderProfile.fromJson(Map<String, dynamic> j) {
    return ProviderProfile(
      branding: ProviderBranding.fromJson(
          (j['branding'] ?? {}) as Map<String, dynamic>),
      billing: j['billing'] != null
          ? ProviderBilling.fromJson(j['billing'] as Map<String, dynamic>)
          : null,
      services: (j['services'] as List?)
              ?.map((s) => ProviderService.fromJson(s as Map<String, dynamic>))
              .toList() ??
          const [],
      widgets: (j['widgets'] as List?)
              ?.map((w) => ProviderWidget.fromJson(w as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// Branding information (logo, accent color, support URL).
class ProviderBranding {
  final String logoUrl;
  final String accentColor;
  final String supportUrl;
  final String providerDescription;

  ProviderBranding({
    this.logoUrl = '',
    this.accentColor = '',
    this.supportUrl = '',
    this.providerDescription = '',
  });

  factory ProviderBranding.fromJson(Map<String, dynamic> j) {
    return ProviderBranding(
      logoUrl: (j['logo_url'] ?? '').toString(),
      accentColor: (j['accent_color'] ?? '').toString(),
      supportUrl: (j['support_url'] ?? '').toString(),
      providerDescription: (j['provider_description'] ?? '').toString(),
    );
  }
}

/// Billing configuration (telegram bot, pricing, payment methods).
class ProviderBilling {
  final String type; // "telegram_bot"
  final String botUsername;
  final String pricingModel; // "daily"
  final Map<String, double> pricePerDay;
  final int trialDays;
  final List<String> paymentMethods;
  final Map<String, String> endpoints;

  ProviderBilling({
    this.type = 'telegram_bot',
    this.botUsername = '',
    this.pricingModel = 'daily',
    this.pricePerDay = const {},
    this.trialDays = 0,
    this.paymentMethods = const [],
    this.endpoints = const {},
  });

  factory ProviderBilling.fromJson(Map<String, dynamic> j) {
    Map<String, double> parsePrices(dynamic raw) {
      if (raw is! Map) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
    }

    Map<String, String> parseEndpoints(dynamic raw) {
      if (raw is! Map) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    return ProviderBilling(
      type: (j['type'] ?? 'telegram_bot').toString(),
      botUsername: (j['bot_username'] ?? '').toString(),
      pricingModel: (j['pricing_model'] ?? 'daily').toString(),
      pricePerDay: parsePrices(j['price_per_day']),
      trialDays: (j['trial_days'] ?? 0) as int,
      paymentMethods:
          (j['payment_methods'] as List?)?.map((m) => m.toString()).toList() ??
              const [],
      endpoints: parseEndpoints(j['endpoints']),
    );
  }
}

/// A provider-defined service/action card (speed test, support link, etc).
class ProviderService {
  final String id;
  final String type; // action, link, web_view, proxy_picker, value_display
  final String title;
  final String description;
  final String icon;
  final Map<String, dynamic> config;

  ProviderService({
    required this.id,
    required this.type,
    required this.title,
    this.description = '',
    this.icon = '',
    this.config = const {},
  });

  factory ProviderService.fromJson(Map<String, dynamic> j) {
    return ProviderService(
      id: (j['id'] ?? '').toString(),
      type: (j['type'] ?? 'action').toString(),
      title: (j['title'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      icon: (j['icon'] ?? '').toString(),
      config: (j['config'] ?? {}) as Map<String, dynamic>,
    );
  }
}

/// A provider-defined stats widget (balance card, traffic card).
class ProviderWidget {
  final String id;
  final String type; // stats_card, progress_bar
  final String title;
  final String dataSource; // /v1/billing/balance
  final List<String> fields;

  ProviderWidget({
    required this.id,
    required this.type,
    required this.title,
    this.dataSource = '',
    this.fields = const [],
  });

  factory ProviderWidget.fromJson(Map<String, dynamic> j) {
    return ProviderWidget(
      id: (j['id'] ?? '').toString(),
      type: (j['type'] ?? 'stats_card').toString(),
      title: (j['title'] ?? '').toString(),
      dataSource: (j['data_source'] ?? '').toString(),
      fields:
          (j['fields'] as List?)?.map((f) => f.toString()).toList() ?? const [],
    );
  }
}
