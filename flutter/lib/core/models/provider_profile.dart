/// ProviderProfile — provider-defined UI/branding/billing/services manifest section.
/// Matches Go: proto.ProviderProfile
library;

/// Top-level provider manifest returned by GET /v1/manifest.
class ProviderManifest {
  final String providerName;
  final String userTier;
  final List<ManifestGroup> groups;
  final ProviderProfile? profile;

  ProviderManifest({
    required this.providerName,
    this.userTier = 'free',
    this.groups = const [],
    this.profile,
  });

  factory ProviderManifest.fromJson(Map<String, dynamic> j) {
    return ProviderManifest(
      providerName: (j['provider_name'] ?? '').toString(),
      userTier: (j['user_tier'] ?? 'free').toString(),
      groups: (j['groups'] as List?)
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

/// A node group in the manifest (region, pool, whitelist, etc).
class ManifestGroup {
  final String id;
  final String title;
  final String type; // urltest, fallback, weighted_round_robin, direct_node
  final String userTier;
  final String badge;
  final String category;
  final String icon;
  final String description;
  final List<ManifestNode> nodes;
  final int pingInterval;
  final int maxRetries;
  final int failoverDelay;

  ManifestGroup({
    required this.id,
    required this.title,
    this.type = 'urltest',
    this.userTier = 'free',
    this.badge = '',
    this.category = '',
    this.icon = '',
    this.description = '',
    this.nodes = const [],
    this.pingInterval = 30,
    this.maxRetries = 3,
    this.failoverDelay = 5,
  });

  factory ManifestGroup.fromJson(Map<String, dynamic> j) {
    return ManifestGroup(
      id: (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      type: (j['type'] ?? 'urltest').toString(),
      userTier: (j['user_tier'] ?? 'free').toString(),
      badge: (j['badge'] ?? '').toString(),
      category: (j['category'] ?? '').toString(),
      icon: (j['icon'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      nodes: (j['nodes'] as List?)
              ?.map((n) => ManifestNode.fromJson(n as Map<String, dynamic>))
              .toList() ??
          const [],
      pingInterval: (j['ping_interval'] ?? 30) as int,
      maxRetries: (j['max_retries'] ?? 3) as int,
      failoverDelay: (j['failover_delay'] ?? 5) as int,
    );
  }

  String get strategyLabel {
    switch (type) {
      case 'urltest':
        return 'Auto (lowest ping)';
      case 'fallback':
        return 'Fallback (priority)';
      case 'weighted_round_robin':
        return 'Round-robin (weighted)';
      case 'direct_node':
        return 'Direct';
      default:
        return type;
    }
  }
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
      paymentMethods: (j['payment_methods'] as List?)
              ?.map((m) => m.toString())
              .toList() ??
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
      fields: (j['fields'] as List?)?.map((f) => f.toString()).toList() ??
          const [],
    );
  }
}
