import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/android_mosaic_account_service.dart';
import '../services/android_vpn_service.dart';
import 'unavailable_daemon_api.dart';

/// Android-side API facade.
///
/// Android intentionally has no desktop loopback mosaicd. Account, manifest and
/// subscription metadata therefore use the hosted authority, while tunnel
/// operations continue through [AndroidVpnService]. Only desktop-only daemon
/// operations remain unavailable; they must not make the whole account UI fail.
class AndroidHostedDaemonApi extends UnavailableDaemonApi {
  AndroidHostedDaemonApi._();

  static final AndroidHostedDaemonApi instance = AndroidHostedDaemonApi._();

  static const _subscriptionsKey = 'mosaic.android.subscriptions.v1';
  static const _preferencesKey = 'mosaic.android.preferences.v1';
  static const _localServersKey = 'mosaic.android.local_servers.v1';
  static const _localGroupsKey = 'mosaic.android.local_groups.v1';
  static const _localSubscriptionID = 'local-default';
  final _account = AndroidMosaicAccountService.instance;
  Server? _activeRoute;

  /// Candidates of the most recent [getCandidateShard] call, keyed by opaque
  /// tag. Kept in-memory only: probe results must never outlive the feed that
  /// defined them, and credentials stay inside the process boundary.
  Map<String, Map<String, dynamic>> _candidateCache = const {};

  /// Reads the per-app split-tunneling lists from stored preferences. Applied
  /// at connect time so preset/profile changes take effect on the next
  /// connection without a daemon restart.
  Future<({List<String> bypassPackages, List<String> proxyPackages})>
      _readPerAppLists() async {
    try {
      final prefs = await getPrefs();
      return (
        bypassPackages: prefs.bypassProcesses,
        proxyPackages: prefs.proxyPackages,
      );
    } catch (_) {
      return (
        bypassPackages: const <String>[],
        proxyPackages: const <String>[]
      );
    }
  }

  /// The route the native runtime is currently connected to, or `null`.
  /// Exposed for the status poller so the dashboard and the Routes screen
  /// highlight the same, actually connected row.
  Server? get activeRoute => _activeRoute;

  /// Starts Android's native TUN runtime and commits a connected route only
  /// after the service reports its terminal `connected` state. This must never
  /// call desktop-only daemon methods: Android has no loopback mosaicd.
  Future<void> _startNativeRoute({
    required String config,
    required Server route,
  }) async {
    final vpn = AndroidVpnService.instance;
    if (!await vpn.requestPermission()) {
      throw StateError(
        'Разрешение на создание VPN-подключения не получено. '
        'Разрешите VPN в системном окне Android и повторите попытку.',
      );
    }
    final state = await vpn.startAndAwaitReady(config);
    if (!state.isConnected) {
      throw StateError(
        state.error?.trim().isNotEmpty == true
            ? state.error!
            : 'Android VPN runtime не подтвердил подключение.',
      );
    }
    _activeRoute = route;
  }

  /// Streams native runtime log lines into the shared logs screen. The libbox
  /// event stream is not wired on the hosted Android facade, so the screen is
  /// fed from the incremental native log buffer keyed by sequence numbers.
  @override
  Stream<(String, Map<String, dynamic>)> events() async* {
    final vpn = AndroidVpnService.instance;
    var afterSeq = 0;
    while (true) {
      try {
        final batch = await vpn.readNativeLogs(afterSeq: afterSeq);
        afterSeq = batch.lastSeq;
        for (final (seq, line) in batch.lines) {
          final level = line.startsWith('error:') ? 'ERROR' : 'INFO';
          yield ('log', {'level': level, 'msg': line, 'seq': seq});
        }
      } catch (_) {
        yield (
          'log',
          {
            'level': 'WARNING',
            'msg': 'Нативный журнал недоступен (runtime не запущен).'
          }
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  Future<VpnStatus> getStatus() async {
    final state = await AndroidVpnService.instance.status();
    if (!state.isConnected) _activeRoute = null;
    return VpnStatus(
      agentConnected: true,
      state: state.state,
      tunnelMode: 'tun',
      server: state.isConnected ? _activeRoute : null,
      lastError: state.error ?? '',
    );
  }

  @override
  Future<void> connect(String serverID) async {
    final perApp = await _readPerAppLists();
    final server = (await listServers()).cast<Server?>().firstWhere(
          (value) => value?.id == serverID,
          orElse: () => null,
        );
    if (server == null) {
      throw StateError(
          'Маршрут не найден. Обновите подписку и повторите попытку.');
    }
    final importUri = server.importUri.trim();
    if (importUri.isEmpty) {
      throw StateError('Этот маршрут не содержит конфигурации для Android.');
    }
    final config = AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(
      importUri,
      bypassPackages: perApp.bypassPackages,
      proxyPackages: perApp.proxyPackages,
    );
    await _startNativeRoute(config: config, route: server);
  }

  @override
  Future<void> connectGroup(String groupID) async {
    final perApp = await _readPerAppLists();
    final resolved = await _resolveMosaicGroup(groupID);
    final manifest = await getProviderManifest(subscriptionId: resolved.$1.id);
    final group = manifest.routes.cast<ManifestGroup?>().firstWhere(
          (value) => value?.id == groupID,
          orElse: () => null,
        );
    if (group == null) {
      throw StateError(
          'Smart Group не найдена. Обновите выбранную подписку и повторите попытку.');
    }
    if (group.disabled) {
      throw StateError(group.disabledReason.isEmpty
          ? 'Этот маршрут пока недоступен.'
          : group.disabledReason);
    }
    final config = group.routeType == 'direct'
        ? await _account.buildNativeTunConfigFromSubscriptionUrl(
            resolved.$1.url,
            bypassPackages: perApp.bypassPackages,
            proxyPackages: perApp.proxyPackages,
          )
        : await _account.buildNativeTunConfigFromScopedCandidates(
            resolved.$1.url,
            groupId: resolved.$2,
            bypassPackages: perApp.bypassPackages,
            proxyPackages: perApp.proxyPackages,
          );
    await _startNativeRoute(
      config: config,
      route: Server(
        id: group.id,
        name: group.title.isEmpty ? group.id : group.title,
        protocol: Protocol.custom,
        tag: group.id,
        outboundTag: group.id,
        subscriptionID: resolved.$1.id,
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    // Stopping is best-effort: the native runtime may already be gone.
    try {
      final vpn = AndroidVpnService.instance;
      var state = await vpn.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (state.state != 'disconnected' &&
          state.state != 'error' &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        state = await vpn.status();
      }
    } finally {
      // Never leave a phantom active route if the platform channel or service
      // disappeared while stopping.
      _activeRoute = null;
    }
  }

  /// Measures TCP reachability and round-trip time to a server endpoint.
  /// Android has no loopback mosaicd to run a full sing-box urlTest, so the
  /// hosted facade probes the real server address directly. A successful
  /// handshake is genuine evidence the endpoint answers; it cannot validate
  /// protocol credentials, but it is exactly what a "ping" column promises.
  Future<int?> _probeTcpLatency(String host, int port) async {
    if (host.isEmpty || port <= 0 || port > 65535) return null;
    List<InternetAddress> target = const [];
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      target = [address];
    } else {
      try {
        target = await InternetAddress.lookup(
          host,
          type: InternetAddressType.any,
        );
      } on SocketException {
        return null;
      }
    }
    for (final candidate in target) {
      final watch = Stopwatch()..start();
      try {
        final socket = await Socket.connect(
          candidate,
          port,
          timeout: const Duration(seconds: 4),
        );
        watch.stop();
        socket.destroy();
        return watch.elapsedMilliseconds;
      } on SocketException {
        watch.stop();
      } on TimeoutException {
        watch.stop();
      }
    }
    return null;
  }

  (String, int)? _endpointOfShareUri(String importUri) {
    final uri = Uri.tryParse(importUri.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 443;
    return (uri.host, port <= 0 ? 443 : port);
  }

  @override
  Future<TestResult> testServer(String id) async {
    final server = (await listServers()).cast<Server?>().firstWhere(
          (value) => value?.id == id,
          orElse: () => null,
        );
    if (server == null) {
      throw StateError('Маршрут не найден. Обновите подписку и повторите.');
    }
    final endpoint = _endpointOfShareUri(server.importUri);
    final latency = endpoint == null
        ? null
        : await _probeTcpLatency(endpoint.$1, endpoint.$2);
    return TestResult(
      serverID: server.id,
      serverName: server.name,
      latencyMS: latency ?? -1,
      error: latency == null ? 'Сервер не отвечает' : '',
    );
  }

  /// Probes a manifest direct route ("Mosaic Direct") with a plain TCP
  /// handshake, exactly like an ordinary server row. Direct routes carry no
  /// candidate feed, so routing this through the Smart Group runner used to
  /// surface misleading "candidate is stale / Smart Group not found" errors
  /// on a single server.
  @override
  Future<TestResult> testDirectRoute(String groupID) async {
    final resolved = await _resolveMosaicGroup(groupID);
    final manifest = await getProviderManifest(subscriptionId: resolved.$1.id);
    final group = manifest.routes.cast<ManifestGroup?>().firstWhere(
          (value) => value?.id == groupID,
          orElse: () => null,
        );
    if (group == null) {
      throw StateError('Маршрут не найден. Обновите подписку и повторите.');
    }
    if (group.routeType == 'smart_group') {
      throw StateError(
          'Это Smart Group. Используйте проверку задержки для групп.');
    }
    final uris = await _account.fetchSubscriptionShareUris(resolved.$1.url);
    (String, int)? endpoint;
    for (final uriText in uris) {
      endpoint = _endpointOfShareUri(uriText);
      if (endpoint != null) break;
    }
    final latency = endpoint == null
        ? null
        : await _probeTcpLatency(endpoint.$1, endpoint.$2);
    return TestResult(
      serverID: group.id,
      serverName: group.title.isEmpty ? group.id : group.title,
      latencyMS: latency ?? -1,
      error: latency == null ? 'Сервер не отвечает' : '',
    );
  }

  @override
  Future<List<TestResult>> testAllServers() async {
    final servers = await listServers();
    final results = <TestResult>[];
    for (final server in servers) {
      final endpoint = _endpointOfShareUri(server.importUri);
      final latency = endpoint == null
          ? null
          : await _probeTcpLatency(endpoint.$1, endpoint.$2);
      results.add(TestResult(
        serverID: server.id,
        serverName: server.name,
        latencyMS: latency ?? -1,
        error: latency == null ? 'Сервер не отвечает' : '',
      ));
    }
    return results;
  }

  /// Downloads the group-scoped candidate feed and exposes its members as
  /// opaque candidate IDs. Desktop asks a local daemon for this shard; on
  /// Android the hosted authority serves the same candidates over HTTPS and
  /// the facade performs the identical membership filtering in-process.
  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID) async {
    final resolved = await _resolveMosaicGroup(groupID);
    final outbounds = await _account.fetchGroupCandidates(
      resolved.$1.url,
      groupId: resolved.$2,
    );
    if (outbounds.isEmpty) {
      throw StateError('Для этой Smart Group нет доступных кандидатов.');
    }
    _candidateCache = {
      for (final outbound in outbounds)
        if (outbound['tag']?.toString().isNotEmpty == true)
          outbound['tag'].toString(): outbound,
    };
    return SmartGroupCandidateShard(
      groupId: groupID,
      version: DateTime.now().millisecondsSinceEpoch.toString(),
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      candidateIds: _candidateCache.keys.toList(growable: false),
    );
  }

  /// Probes one opaque candidate by opening a real TCP connection to its
  /// endpoint. The candidate tag never leaves the device; only aggregate
  /// quality metrics flow back to the caller, matching the desktop contract.
  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
      String groupID, String candidateID) async {
    final outbound = _candidateCache[candidateID];
    if (outbound == null) {
      throw StateError(
          'Кандидат устарел. Запустите проверку задержки ещё раз.');
    }
    final host = outbound['server']?.toString() ?? '';
    final port = int.tryParse(outbound['server_port']?.toString() ?? '') ?? 443;
    final latency = await _probeTcpLatency(host, port);
    return SmartGroupProbeResult(
      groupId: groupID,
      candidateId: candidateID,
      successful: latency != null,
      samples: 1,
      successes: latency != null ? 1 : 0,
      lossPercent: latency != null ? 0 : 100,
      medianLatencyMs: latency ?? 0,
      p95LatencyMs: latency ?? 0,
      jitterMs: 0,
      checkedAt: DateTime.now().toUtc(),
      probeKind: 'tcp-handshake',
    );
  }

  bool _isMosaicSubscriptionUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.isScheme('https') &&
        uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
        uri.pathSegments.isNotEmpty;
  }

  /// Converts the v0.3.22 special provider row into the user-owned URL
  /// source it always represented. Provider cabinet access is attached later;
  /// it must not alter the subscription's parsing, connection or deletion
  /// lifecycle.
  Subscription _asUrlSubscription(Subscription value) => Subscription(
        id: value.id.isEmpty
            ? 'android-local-${DateTime.now().microsecondsSinceEpoch}'
            : value.id,
        name: value.name.trim().isEmpty ? 'MosaicVPN' : value.name,
        url: value.url.trim(),
        autoRefresh: value.autoRefresh,
        refreshIntervalSeconds: value.refreshIntervalSeconds,
        serverCount: value.serverCount,
        lastFetched: value.lastFetched,
        hasError: value.hasError,
        lastError: value.lastError,
        source: 'url',
      );

  bool _isMosaicSubscription(Subscription value) =>
      _isMosaicSubscriptionUrl(value.url);

  String _scopedGroupID(String subscriptionID, String manifestGroupID) =>
      'provider:$subscriptionID:$manifestGroupID';

  ({String subscriptionID, String manifestGroupID})? _parseScopedGroupID(
      String value) {
    const prefix = 'provider:';
    if (!value.startsWith(prefix)) {
      return null;
    }
    final delimiter = value.indexOf(':', prefix.length);
    if (delimiter <= prefix.length || delimiter == value.length - 1) {
      return null;
    }
    return (
      subscriptionID: value.substring(prefix.length, delimiter),
      manifestGroupID: value.substring(delimiter + 1),
    );
  }

  Future<(Subscription, String)> _resolveMosaicGroup(String groupID) async {
    final subscriptions = await listSubscriptions();
    final scoped = _parseScopedGroupID(groupID);
    if (scoped != null) {
      final subscription = subscriptions.cast<Subscription?>().firstWhere(
            (value) => value?.id == scoped.subscriptionID,
            orElse: () => null,
          );
      if (subscription != null && _isMosaicSubscription(subscription)) {
        return (subscription, scoped.manifestGroupID);
      }
      throw StateError(
          'Подписка для Smart Group не найдена. Обновите список источников.');
    }

    // Compatibility with a raw group ID returned by a pre-v0.3.23 screen.
    final mosaicSources =
        subscriptions.where(_isMosaicSubscription).toList(growable: false);
    if (mosaicSources.length == 1) return (mosaicSources.single, groupID);
    throw StateError(
        'Не удалось определить подписку Smart Group. Откройте маршруты нужной подписки и повторите попытку.');
  }

  ProviderManifest _scopeManifest(
      ProviderManifest manifest, String subscriptionID) {
    if (subscriptionID.isEmpty) return manifest;
    ManifestGroup scopedRoute(ManifestGroup route) => ManifestGroup(
          id: _scopedGroupID(subscriptionID, route.id),
          title: route.title,
          routeType: route.routeType,
          type: route.type,
          poolId: route.poolId,
          countryCode: route.countryCode,
          protocol: route.protocol,
          userTier: route.userTier,
          badge: route.badge,
          category: route.category,
          icon: route.icon,
          description: route.description,
          disabled: route.disabled,
          disabledReason: route.disabledReason,
          clientPolicy: route.clientPolicy,
          nodes: route.nodes,
          pingInterval: route.pingInterval,
          maxRetries: route.maxRetries,
          failoverDelay: route.failoverDelay,
        );
    return ProviderManifest(
      providerName: manifest.providerName,
      userTier: manifest.userTier,
      profile: manifest.profile,
      groups: manifest.groups.map(scopedRoute).toList(growable: false),
      directRoutes:
          manifest.directRoutes.map(scopedRoute).toList(growable: false),
    );
  }

  Future<List<Subscription>> _readLocalSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subscriptionsKey);
    if (raw == null || raw.isEmpty) return <Subscription>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Subscription>[];
      return decoded
          .whereType<Map>()
          .map((value) =>
              Subscription.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: true);
    } catch (_) {
      return <Subscription>[];
    }
  }

  Future<void> _writeLocalSubscriptions(List<Subscription> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _subscriptionsKey,
      jsonEncode(values.map((value) => value.toJson()).toList()),
    );
  }

  Future<List<Server>> _readLocalServers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localServersKey);
    if (raw == null || raw.isEmpty) return <Server>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Server>[];
      return decoded
          .whereType<Map>()
          .map((value) => Server.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: true);
    } catch (_) {
      return <Server>[];
    }
  }

  Future<void> _writeLocalServers(List<Server> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localServersKey,
      jsonEncode(values.map((value) => value.toJson()).toList()),
    );
  }

  Future<List<ServerGroup>> _readLocalGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localGroupsKey);
    if (raw == null || raw.isEmpty) return <ServerGroup>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ServerGroup>[];
      return decoded
          .whereType<Map>()
          .map(
              (value) => ServerGroup.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: true);
    } catch (_) {
      return <ServerGroup>[];
    }
  }

  Future<void> _writeLocalGroups(List<ServerGroup> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localGroupsKey,
      jsonEncode(values.map((value) => value.toJson()).toList()),
    );
  }

  Future<Subscription?> _localSubscription() async {
    final servers = await _readLocalServers();
    final groups = await _readLocalGroups();
    if (servers.isEmpty && groups.isEmpty) return null;
    return Subscription(
      id: _localSubscriptionID,
      name: 'Локальные профили',
      serverCount: servers.length,
      source: 'local',
    );
  }

  /// Completes a user-initiated website enrollment and persists the managed
  /// provider source exactly once. Re-enrollment is idempotent by provider
  /// account identity; it updates the existing subscription instead of adding
  /// another global/account-derived row.
  Future<Subscription?> completeWebsiteEnrollmentIfPresent() async {
    final session = await _account.completeEnrollmentIfPresent();
    if (session == null) return null;
    final providerId = session.providerId?.trim().isNotEmpty == true
        ? session.providerId!.trim()
        : 'mosaicvpn';
    final providerAccountId =
        session.providerAccountId?.trim().isNotEmpty == true
            ? session.providerAccountId!.trim()
            : 'mosaicvpn-default';
    return enrollProviderSubscription(
      providerId: providerId,
      providerAccountId: providerAccountId,
      subscriptionName: session.subscriptionName?.trim().isNotEmpty == true
          ? session.subscriptionName!.trim()
          : 'MosaicVPN',
      subscriptionUrl: session.subscriptionUrl?.trim().isNotEmpty == true
          ? session.subscriptionUrl!.trim()
          : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}',
    );
  }

  @override
  Future<List<Subscription>> listSubscriptions() async {
    final localSource = await _localSubscription();
    final stored = await _readLocalSubscriptions();
    var migrated = false;
    final normalized = <Subscription>[];
    final urls = <String>{};
    for (final value in stored) {
      final legacyMosaicProvider =
          value.isProviderSource && _isMosaicSubscriptionUrl(value.url);
      final current = legacyMosaicProvider ? _asUrlSubscription(value) : value;
      migrated = migrated || legacyMosaicProvider;
      // Keep the first row in user-defined order when a previous website flow
      // left both a generic import and a provider mirror for the same URL.
      final key = current.url.trim();
      if (key.isNotEmpty && !urls.add(key)) {
        migrated = true;
        continue;
      }
      normalized.add(current);
    }
    if (migrated) await _writeLocalSubscriptions(normalized);
    return [
      if (localSource != null) localSource,
      ...normalized.where((value) => value.id != _localSubscriptionID),
    ];
  }

  @override
  Future<Subscription> addSubscription(
    String name,
    String url, {
    bool autoRefresh = false,
    int refreshInterval = 3600,
  }) async {
    final normalized = url.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Введите URL подписки.');
    }
    final values = await _readLocalSubscriptions();
    final matches = values.where((value) => value.url == normalized);
    if (matches.isNotEmpty) return matches.first;

    // Android keeps user-imported links locally. Every compatible imported
    // profile can build a direct native TUN route when the user selects one.
    final imported = Subscription(
      id: 'android-local-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Локальная подписка' : name.trim(),
      url: normalized,
      autoRefresh: autoRefresh,
      refreshIntervalSeconds: refreshInterval,
    );
    values.add(imported);
    await _writeLocalSubscriptions(values);
    return imported;
  }

  @override
  Future<Subscription> enrollProviderSubscription({
    required String providerId,
    required String providerAccountId,
    required String subscriptionName,
    required String subscriptionUrl,
    String? sessionToken,
    String? directToken,
    String? username,
  }) async {
    if (providerId.trim() != 'mosaicvpn' ||
        providerAccountId.trim().isEmpty ||
        !_isMosaicSubscriptionUrl(subscriptionUrl)) {
      throw const FormatException('Некорректные данные подписки MosaicVPN.');
    }
    // Website enrollment is an import transport, not a special subscription
    // type. It updates the matching ordinary URL row in-place and lets a later
    // cabinet-binding layer own provider account credentials separately.
    final current = await listSubscriptions();
    final existing = current.cast<Subscription?>().firstWhere(
          (value) => value?.url.trim() == subscriptionUrl.trim(),
          orElse: () => null,
        );
    Subscription stored;
    if (existing != null) {
      final values = await _readLocalSubscriptions();
      final index = values.indexWhere((value) => value.id == existing.id);
      if (index >= 0) {
        values[index] = Subscription(
          id: existing.id,
          name: subscriptionName.trim().isEmpty
              ? existing.name
              : subscriptionName.trim(),
          url: subscriptionUrl.trim(),
          autoRefresh: true,
          refreshIntervalSeconds: existing.refreshIntervalSeconds,
          serverCount: existing.serverCount,
          lastFetched: existing.lastFetched,
          hasError: existing.hasError,
          lastError: existing.lastError,
          source: 'url',
        );
        await _writeLocalSubscriptions(values);
        stored = values[index];
      } else {
        stored = await addSubscription(
          subscriptionName.trim().isEmpty
              ? 'MosaicVPN'
              : subscriptionName.trim(),
          subscriptionUrl,
          autoRefresh: true,
        );
      }
    } else {
      stored = await addSubscription(
        subscriptionName.trim().isEmpty ? 'MosaicVPN' : subscriptionName.trim(),
        subscriptionUrl,
        autoRefresh: true,
      );
    }

    // Cabinet credentials belong to this specific local URL source. The URL is
    // still fully usable without this optional record.
    final opaqueID = Uri.parse(subscriptionUrl).pathSegments.last;
    await _account.saveBinding(
      stored.id,
      AndroidMosaicSession(
        directToken: directToken?.trim().isNotEmpty == true
            ? directToken!.trim()
            : opaqueID,
        sessionToken: sessionToken?.trim(),
        username: username?.trim(),
        subscriptionUrl: stored.url,
        providerId: providerId.trim(),
        providerAccountId: providerAccountId.trim(),
        subscriptionName: stored.name,
      ),
    );
    return stored;
  }

  @override
  Future<Subscription> refreshSubscription(String id) async {
    final values = await listSubscriptions();
    final current = values.firstWhere(
      (value) => value.id == id,
      orElse: () => throw StateError('Подписка не найдена.'),
    );
    // Mosaic sources expose their route count through the capability manifest;
    // physical feed rows are intentionally hidden, so the stored counter must
    // come from the manifest instead of the (never parsed) share-URI list.
    if (_isMosaicSubscription(current)) {
      try {
        final manifest = await _account.getProviderManifest();
        final visible =
            manifest.routes.where((group) => group.category != 'raw').length;
        if (visible != current.serverCount) {
          final updated = Subscription(
            id: current.id,
            name: current.name,
            url: current.url,
            autoRefresh: current.autoRefresh,
            refreshIntervalSeconds: current.refreshIntervalSeconds,
            serverCount: visible,
            lastFetched: DateTime.now(),
            hasError: current.hasError,
            lastError: current.lastError,
            source: current.source,
            providerId: current.providerId,
            providerAccountId: current.providerAccountId,
            hidePhysicalNodes: current.hidePhysicalNodes,
          );
          return _updateStoredSubscription(current, (_) => updated);
        }
      } catch (_) {
        // Keep the previous counter on a transient manifest failure.
      }
    }
    return current;
  }

  Future<Subscription> _updateStoredSubscription(Subscription current,
      Subscription Function(Subscription) transform) async {
    final updated = transform(current);
    final stored = await _readLocalSubscriptions();
    final index = stored.indexWhere((value) => value.id == current.id);
    if (index >= 0) {
      stored[index] = updated;
      await _writeLocalSubscriptions(stored);
    }
    return updated;
  }

  @override
  Future<void> renameSubscription(String id, String name) async {
    if (id == _localSubscriptionID) {
      return;
    }
    final values = await _readLocalSubscriptions();
    final index = values.indexWhere((value) => value.id == id);
    if (index < 0) throw StateError('Подписка не найдена.');
    values[index] = Subscription(
      id: values[index].id,
      name: name.trim().isEmpty ? values[index].name : name.trim(),
      url: values[index].url,
      autoRefresh: values[index].autoRefresh,
      refreshIntervalSeconds: values[index].refreshIntervalSeconds,
      serverCount: values[index].serverCount,
      lastFetched: values[index].lastFetched,
      hasError: values[index].hasError,
      lastError: values[index].lastError,
      source: values[index].source,
      providerId: values[index].providerId,
      providerAccountId: values[index].providerAccountId,
      hidePhysicalNodes: values[index].hidePhysicalNodes,
    );
    await _writeLocalSubscriptions(values);
  }

  @override
  Future<void> deleteSubscription(String id) async {
    if (id == _localSubscriptionID) {
      throw StateError(
          'Локальный сборник удаляется через его серверы и группы.');
    }
    final values = await _readLocalSubscriptions();
    values.removeWhere((value) => value.id == id);
    await _writeLocalSubscriptions(values);
    await _account.clearBinding(id);
  }

  @override
  Future<List<Subscription>> reorderSubscriptions(
      List<String> subscriptionIDs) async {
    final all = await listSubscriptions();
    final byID = {for (final value in all) value.id: value};
    final reordered = <Subscription>[];
    for (final id in subscriptionIDs) {
      final value = byID.remove(id);
      if (value != null) reordered.add(value);
    }
    reordered.addAll(byID.values);
    final local = reordered
        .where((value) => value.id != _localSubscriptionID)
        .toList(growable: false);
    await _writeLocalSubscriptions(local);
    return [
      if (await _localSubscription() != null) (await _localSubscription())!,
      ...local,
    ];
  }

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async {
    final subscriptions = await listSubscriptions();
    final result = <Server>[];
    if (subscriptionID == null || subscriptionID == _localSubscriptionID) {
      result.addAll(await _readLocalServers());
    }
    for (final subscription in subscriptions) {
      // A Mosaic URL may expose Smart Groups through its manifest. Never render
      // the implementation feed's physical pool rows, but retain ordinary URL
      // ownership, deletion and connection semantics for the subscription.
      if (_isMosaicSubscription(subscription)) continue;
      if (subscription.id == _localSubscriptionID) continue;
      if (subscriptionID != null && subscription.id != subscriptionID) continue;
      try {
        final links =
            await _account.fetchSubscriptionShareUris(subscription.url);
        for (var index = 0; index < links.length; index++) {
          final link = links[index];
          final uri = Uri.tryParse(link);
          if (uri == null || uri.scheme.isEmpty) continue;
          final label = uri.fragment.isEmpty
              ? '${uri.scheme.toUpperCase()} ${uri.host}'
              : Uri.decodeComponent(uri.fragment);
          result.add(Server(
            id: '${subscription.id}:$index',
            name: label,
            protocol: Protocol.fromString(
                uri.scheme == 'ss' ? 'shadowsocks' : uri.scheme),
            address: uri.host,
            port: uri.hasPort ? uri.port : 0,
            tag: label,
            outboundTag: label,
            subscriptionID: subscription.id,
            importUri: link,
          ));
        }
      } catch (_) {
        // The Subscription row remains available with its actual fetch error
        // surfaced by manual refresh/connect rather than fabricated servers.
      }
    }
    return result;
  }

  @override
  Future<void> addServer(Server s) async {
    final values = await _readLocalServers();
    final now = DateTime.now().microsecondsSinceEpoch;
    final groupId = s.tag.isNotEmpty ? s.tag : s.groupId;
    final normalized = s.copyWith(
      id: s.id.isEmpty ? 'android-local-server-$now' : s.id,
      subscriptionID: _localSubscriptionID,
      groupId: groupId,
      tag: groupId,
    );
    values.removeWhere((value) => value.id == normalized.id);
    values.add(normalized);
    await _writeLocalServers(values);
  }

  @override
  Future<void> deleteServer(String id) async {
    final values = await _readLocalServers();
    final before = values.length;
    values.removeWhere((value) => value.id == id);
    if (values.length == before) {
      throw StateError('Локальный сервер не найден.');
    }
    await _writeLocalServers(values);
  }

  @override
  Future<List<ServerGroup>> listGroups() async {
    final values = await _readLocalGroups();
    return values
      ..sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
  }

  @override
  Future<ServerGroup> createGroup(String name) async {
    final label = name.trim();
    if (label.isEmpty) {
      throw const FormatException('Введите название сборника.');
    }
    final values = await _readLocalGroups();
    final group = ServerGroup(
      id: 'android-local-group-${DateTime.now().microsecondsSinceEpoch}',
      name: label,
      sortOrder: values.length,
    );
    values.add(group);
    await _writeLocalGroups(values);
    return group;
  }

  @override
  Future<void> deleteGroup(String id) async {
    final groups = await _readLocalGroups();
    final exists = groups.any((group) => group.id == id);
    if (!exists) throw StateError('Локальный сборник не найден.');
    groups.removeWhere((group) => group.id == id);
    final servers = await _readLocalServers();
    final updated = servers
        .map((server) => server.groupId == id
            ? server.copyWith(groupId: '', tag: '')
            : server)
        .toList(growable: false);
    await _writeLocalGroups(groups);
    await _writeLocalServers(updated);
  }

  @override
  Future<void> moveToGroup(String serverId, String groupId) async {
    final groups = await _readLocalGroups();
    if (groupId.isNotEmpty && !groups.any((group) => group.id == groupId)) {
      throw StateError('Локальный сборник не найден.');
    }
    final servers = await _readLocalServers();
    final index = servers.indexWhere((server) => server.id == serverId);
    if (index < 0) throw StateError('Локальный сервер не найден.');
    servers[index] = servers[index].copyWith(groupId: groupId, tag: groupId);
    await _writeLocalServers(servers);
  }

  @override
  Future<Preferences> getPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preferencesKey);
    if (raw == null || raw.isEmpty) return Preferences();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Preferences.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // A malformed old local value must not prevent settings from opening.
    }
    return Preferences();
  }

  @override
  Future<Preferences> setPrefs(Map<String, dynamic> prefs) async {
    final current = await getPrefs();
    final merged = <String, dynamic>{...current.toJson(), ...prefs};
    final updated = Preferences.fromJson(merged);
    final storage = await SharedPreferences.getInstance();
    await storage.setString(_preferencesKey, jsonEncode(updated.toJson()));
    return updated;
  }

  @override
  Future<UnifiedAccount?> getUnifiedAccount() => _account.getUnifiedAccount();

  @override
  Future<UnifiedAccount> freezeAccount() => _account.setFrozen(true);

  @override
  Future<UnifiedAccount> unfreezeAccount() => _account.setFrozen(false);

  @override
  Future<List<CheckoutProviderOption>> getCheckoutOptions() =>
      _account.getCheckoutOptions();

  @override
  Future<CheckoutSession> createCheckout({
    required int amountRub,
    required String provider,
  }) =>
      _account.createCheckout(amountRub: amountRub, provider: provider);

  @override
  Future<RotatedSubscriptionLink> rotateSubscriptionLink() =>
      _account.rotateSubscriptionLink();

  @override
  Future<BillingProfile> getBillingProfile() => _account.getBillingProfile();

  @override
  Future<List<PaymentEntry>> getPaymentHistory() =>
      _account.getPaymentHistory();

  @override
  Future<ProviderManifest> getProviderManifest({String? subscriptionId}) async {
    final manifest = await _account.getProviderManifest();
    if (subscriptionId == null || subscriptionId.isEmpty) return manifest;
    final subscriptions = await listSubscriptions();
    final source = subscriptions.cast<Subscription?>().firstWhere(
          (value) => value?.id == subscriptionId,
          orElse: () => null,
        );
    if (source == null || !_isMosaicSubscription(source)) {
      return ProviderManifest(
        providerName: manifest.providerName,
        userTier: manifest.userTier,
      );
    }
    return _scopeManifest(manifest, subscriptionId);
  }

  @override
  Future<LinkResult> redeemLinkCode(String code,
      {String? subscriptionId}) async {
    if (subscriptionId?.trim().isNotEmpty == true) {
      final subscriptions = await listSubscriptions();
      final selected = subscriptions.cast<Subscription?>().firstWhere(
            (value) => value?.id == subscriptionId,
            orElse: () => null,
          );
      if (selected == null || !_isMosaicSubscription(selected)) {
        throw StateError('Откройте совместимую подписку MosaicVPN.');
      }
      final session = await _account.attachCabinetCode(
        subscriptionID: selected.id,
        subscriptionUrl: selected.url,
        rawCode: code,
      );
      return LinkResult(ok: true, username: session.username ?? '');
    }
    final session = await _account.redeemTelegramCode(code);
    return LinkResult(ok: true, username: session.username ?? '');
  }

  @override
  Future<void> loginWithEmail(String email, String password) async {
    await _account.loginWithEmail(email, password);
  }
}
