import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/android_mosaic_account_service.dart';
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
  static const _mosaicProviderSubscriptionID = 'provider-mosaicvpn-primary';
  final _account = AndroidMosaicAccountService.instance;

  Future<List<Subscription>> _readLocalSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subscriptionsKey);
    if (raw == null || raw.isEmpty) return <Subscription>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Subscription>[];
      return decoded
          .whereType<Map>()
          .map((value) => Subscription.fromJson(
              Map<String, dynamic>.from(value)))
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

  Future<Subscription?> _directSubscription() async {
    final session = await _account.restoreSession();
    if (session == null) return null;
    return Subscription(
      id: _mosaicProviderSubscriptionID,
      name: 'MosaicVPN',
      url: 'https://sub.zxc1x1.ru/api/direct/singbox?token=${Uri.encodeQueryComponent(session.directToken)}',
      autoRefresh: true,
      refreshIntervalSeconds: 3600,
      source: 'provider',
      providerId: 'mosaicvpn',
      providerAccountId: 'mosaicvpn-default',
      hidePhysicalNodes: true,
    );
  }

  @override
  Future<List<Subscription>> listSubscriptions() async {
    final direct = await _directSubscription();
    final local = await _readLocalSubscriptions();
    final filtered = local
        .where((value) => value.id != _mosaicProviderSubscriptionID)
        .toList();
    return [if (direct != null) direct, ...filtered];
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
    final existing = await _directSubscription();
    if (existing != null && normalized == existing.url) return existing;

    // Android keeps user-imported links locally. The Mosaic direct profile is
    // the only profile consumed by the native TUN builder; arbitrary imports
    // remain visible and are intentionally marked until a provider-compatible
    // direct feed is selected instead of being silently treated as a tunnel.
    final values = await _readLocalSubscriptions();
    final subscription = Subscription(
      id: 'android-local-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Локальная подписка' : name.trim(),
      url: normalized,
      autoRefresh: autoRefresh,
      refreshIntervalSeconds: refreshInterval,
    );
    values.add(subscription);
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
    if (id == _mosaicProviderSubscriptionID) return;
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
    final direct = reordered
        .where((value) => value.id == _mosaicProviderSubscriptionID);
    final local = reordered
        .where((value) => value.id != _mosaicProviderSubscriptionID)
        .toList();
    await _writeLocalSubscriptions(local);
    return [...direct, ...local];
  }

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async {
    final subscriptions = await listSubscriptions();
    final result = <Server>[];
    for (final subscription in subscriptions) {
      // Protected provider feeds expose their manifest Smart Groups, not pool
      // candidates. User-owned and provider-published ordinary rows are parsed.
      if (subscription.isProviderSource && subscription.hidePhysicalNodes) {
        continue;
      }
      if (subscriptionID != null && subscription.id != subscriptionID) continue;
      try {
        final links = await _account.fetchSubscriptionShareUris(subscription.url);
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
            protocol: Protocol.fromString(uri.scheme == 'ss' ? 'shadowsocks' : uri.scheme),
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
  }) => _account.createCheckout(amountRub: amountRub, provider: provider);

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
