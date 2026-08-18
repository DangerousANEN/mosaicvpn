import 'dart:convert';

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
  static const _mosaicProviderSubscriptionID = 'provider-mosaicvpn-primary';
  final _account = AndroidMosaicAccountService.instance;
  Server? _activeRoute;

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
    final config =
        AndroidMosaicAccountService.buildNativeTunConfigFromShareUri(importUri);
    await _startNativeRoute(config: config, route: server);
  }

  @override
  Future<void> connectGroup(String groupID) async {
    final manifest = await _account.getProviderManifest();
    final group = manifest.groups.cast<ManifestGroup?>().firstWhere(
          (value) => value?.id == groupID,
          orElse: () => null,
        );
    if (group == null) {
      throw StateError(
          'Smart Group не найден. Обновите подписку и повторите попытку.');
    }
    if (group.disabled) {
      throw StateError(group.disabledReason.isEmpty
          ? 'Этот маршрут пока недоступен.'
          : group.disabledReason);
    }
    final config = await _account.buildNativeTunConfig(groupId: groupID);
    await _startNativeRoute(
      config: config,
      route: Server(
        id: group.id,
        name: group.title.isEmpty ? group.id : group.title,
        protocol: Protocol.custom,
        tag: group.id,
        outboundTag: group.id,
        subscriptionID: _mosaicProviderSubscriptionID,
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    final state = await AndroidVpnService.instance.stop();
    if (state.state != 'disconnected') {
      throw StateError(state.error?.trim().isNotEmpty == true
          ? state.error!
          : 'Android VPN runtime не подтвердил остановку.');
    }
    _activeRoute = null;
  }

  bool _isMosaicSubscriptionUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.isScheme('https') &&
        uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
        uri.pathSegments.isNotEmpty;
  }

  Subscription _asMosaicProviderSource(Subscription value) {
    final opaqueLinkID = value.url.trim().split('/').last;
    return Subscription(
      id: value.id.isEmpty ? _mosaicProviderSubscriptionID : value.id,
      name: value.name.trim().isEmpty ? 'MosaicVPN' : value.name,
      url: value.url,
      autoRefresh: value.autoRefresh,
      refreshIntervalSeconds: value.refreshIntervalSeconds,
      serverCount: value.serverCount,
      lastFetched: value.lastFetched,
      hasError: value.hasError,
      lastError: value.lastError,
      source: 'provider',
      providerId: 'mosaicvpn',
      // A manually imported link has not authenticated its billing identity.
      // Keep a device-local opaque link key until website enrollment attaches
      // the authenticated provider account without exposing the raw node pool.
      providerAccountId: value.providerAccountId.isNotEmpty
          ? value.providerAccountId
          : 'unlinked:$opaqueLinkID',
      hidePhysicalNodes: true,
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
    final normalized = stored.map((value) {
      if (!value.isProviderSource && _isMosaicSubscriptionUrl(value.url)) {
        migrated = true;
        return _asMosaicProviderSource(value);
      }
      return value;
    }).toList(growable: true);
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
    final subscription = _isMosaicSubscriptionUrl(normalized)
        ? _asMosaicProviderSource(imported)
        : imported;
    values.add(subscription);
    await _writeLocalSubscriptions(values);
    return subscription;
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
    final values = await _readLocalSubscriptions();
    final existingIndex = values.indexWhere((value) =>
        value.providerId == providerId &&
        value.providerAccountId == providerAccountId);
    final existing = existingIndex >= 0 ? values[existingIndex] : null;
    final subscription = Subscription(
      id: existing?.id.isNotEmpty == true
          ? existing!.id
          : _mosaicProviderSubscriptionID,
      name: subscriptionName.trim().isEmpty
          ? 'MosaicVPN'
          : subscriptionName.trim(),
      url: subscriptionUrl.trim(),
      autoRefresh: true,
      refreshIntervalSeconds: 3600,
      source: 'provider',
      providerId: providerId,
      providerAccountId: providerAccountId,
      hidePhysicalNodes: true,
    );
    if (existingIndex >= 0) {
      values[existingIndex] = subscription;
    } else {
      values.removeWhere((value) =>
          value.url.trim() == subscription.url && !value.isProviderSource);
      values.add(subscription);
    }
    await _writeLocalSubscriptions(values);
    return subscription;
  }

  @override
  Future<Subscription> refreshSubscription(String id) async {
    final values = await listSubscriptions();
    final current = values.firstWhere(
      (value) => value.id == id,
      orElse: () => throw StateError('Подписка не найдена.'),
    );
    if (id == _mosaicProviderSubscriptionID) return current;
    return current;
  }

  @override
  Future<void> renameSubscription(String id, String name) async {
    if (id == _mosaicProviderSubscriptionID || id == _localSubscriptionID) {
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
    if (id == _mosaicProviderSubscriptionID) {
      throw StateError('Основную подписку MosaicVPN нельзя удалить.');
    }
    if (id == _localSubscriptionID) {
      throw StateError(
          'Локальный сборник удаляется через его серверы и группы.');
    }
    final values = await _readLocalSubscriptions();
    values.removeWhere((value) => value.id == id);
    await _writeLocalSubscriptions(values);
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
    final direct =
        reordered.where((value) => value.id == _mosaicProviderSubscriptionID);
    final local = reordered
        .where((value) =>
            value.id != _mosaicProviderSubscriptionID &&
            value.id != _localSubscriptionID)
        .toList();
    await _writeLocalSubscriptions(local);
    return [...direct, ...local];
  }

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async {
    final subscriptions = await listSubscriptions();
    final result = <Server>[];
    if (subscriptionID == null || subscriptionID == _localSubscriptionID) {
      result.addAll(await _readLocalServers());
    }
    for (final subscription in subscriptions) {
      // Protected provider feeds expose their manifest Smart Groups, not pool
      // candidates. User-owned and provider-published ordinary rows are parsed.
      if (subscription.isProviderSource && subscription.hidePhysicalNodes) {
        continue;
      }
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
  Future<ProviderManifest> getProviderManifest() =>
      _account.getProviderManifest();

  @override
  Future<LinkResult> redeemLinkCode(String code) async {
    final session = await _account.redeemTelegramCode(code);
    return LinkResult(ok: true, username: session.username ?? '');
  }

  @override
  Future<void> loginWithEmail(String email, String password) async {
    await _account.loginWithEmail(email, password);
  }
}
