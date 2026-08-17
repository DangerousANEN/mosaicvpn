/// Subscription — a remote URL providing server configurations.
/// Matches Go: proto.Subscription
class Subscription {
  final String id;
  final String name;
  final String url;
  final bool autoRefresh;
  final int refreshIntervalSeconds;
  final int serverCount;
  final DateTime lastFetched;
  final bool hasError;
  final String lastError;
  final String source;
  final String providerId;
  final String providerAccountId;
  final bool hidePhysicalNodes;

  Subscription({
    this.id = '',
    this.name = '',
    this.url = '',
    this.autoRefresh = false,
    this.refreshIntervalSeconds = 3600,
    this.serverCount = 0,
    DateTime? lastFetched,
    this.hasError = false,
    this.lastError = '',
    this.source = 'local',
    this.providerId = '',
    this.providerAccountId = '',
    this.hidePhysicalNodes = false,
  }) : lastFetched = lastFetched ?? DateTime.fromMillisecondsSinceEpoch(0);

  bool get isProviderSource => source == 'provider' || providerId.isNotEmpty;


  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        url: j['url'] ?? '',
        autoRefresh: j['auto_refresh'] ?? false,
        refreshIntervalSeconds: j['refresh_interval_seconds'] ?? 3600,
        serverCount: j['server_count'] ?? 0,
        lastFetched: j['last_fetched'] != null
            ? DateTime.tryParse(j['last_fetched'])
            : null,
        hasError: j['has_error'] ?? false,
        lastError: j['last_error'] ?? '',
        source: j['source'] ?? 'local',
        providerId: j['provider_id'] ?? '',
        providerAccountId: j['provider_account_id'] ?? '',
        hidePhysicalNodes: j['hide_physical_nodes'] ?? false,
      );

  /// Serialise to JSON — the inverse of [fromJson]. Used by the backup
  /// pipeline (Phase 2.5).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'auto_refresh': autoRefresh,
        'refresh_interval_seconds': refreshIntervalSeconds,
        'server_count': serverCount,
        'last_fetched': lastFetched.toIso8601String(),
        'has_error': hasError,
        'last_error': lastError,
        'source': source,
        'provider_id': providerId,
        'provider_account_id': providerAccountId,
        'hide_physical_nodes': hidePhysicalNodes,
      };
}
