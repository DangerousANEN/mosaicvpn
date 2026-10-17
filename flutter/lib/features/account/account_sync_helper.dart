import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/daemon_api_base.dart';
import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/android_mosaic_account_service.dart';
import 'unified_account_panel.dart';

/// Abstraction for Android/mobile account credentials exchange, overridable in tests.
abstract class AccountLoginAuthority {
  Future<Uri> beginWebsiteLogin();
  Future<AndroidMosaicSession?> completeWebsiteLoginIfPresent();
  Future<AndroidMosaicSession> redeemTelegramCode(String rawCode);
  Future<AndroidMosaicSession> loginWithEmail(String email, String password);
  Future<AndroidMosaicSession?> restoreSession();
}

/// Production implementation delegating directly to [AndroidMosaicAccountService].
class DefaultAccountLoginAuthority implements AccountLoginAuthority {
  final AndroidMosaicAccountService _service;

  DefaultAccountLoginAuthority([AndroidMosaicAccountService? service])
      : _service = service ?? AndroidMosaicAccountService.instance;

  @override
  Future<Uri> beginWebsiteLogin() => _service.beginWebsiteLogin();

  @override
  Future<AndroidMosaicSession?> completeWebsiteLoginIfPresent() =>
      _service.completeWebsiteLoginIfPresent();

  @override
  Future<AndroidMosaicSession> redeemTelegramCode(String rawCode) =>
      _service.redeemTelegramCode(rawCode);

  @override
  Future<AndroidMosaicSession> loginWithEmail(String email, String password) =>
      _service.loginWithEmail(email, password);

  @override
  Future<AndroidMosaicSession?> restoreSession() => _service.restoreSession();
}

/// Provider for account login operations, overridable for regression tests.
final accountLoginAuthorityProvider = Provider<AccountLoginAuthority>((ref) {
  return DefaultAccountLoginAuthority();
});

/// Shared post-auth synchronization service that registers returned feeds/accounts
/// without duplicate subscriptions and invalidates dependent providers.
class AccountSyncService {
  final DaemonApiBase api;

  AccountSyncService({required this.api});

  static const String routeSyncErrorMessage =
      'Could not sync subscription routes. Tap Retry to recover.';

  final Map<String, Future<Subscription>> _inFlight = {};

  /// Normalizes the subscription URL from an [AndroidMosaicSession].
  static String normalizeSubscriptionUrl(AndroidMosaicSession session) {
    final rawUrl = session.subscriptionUrl?.trim();
    String url;
    if (rawUrl != null && rawUrl.isNotEmpty) {
      url = rawUrl;
      if (!url.startsWith('https://') && !url.startsWith('http://')) {
        url = 'https://$url';
      }
    } else {
      url = 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken.trim())}';
    }
    return url.trim().replaceAll(RegExp(r'\.+$'), '');
  }

  /// Registers the returned feed and account from an authenticated session
  /// via [enrollProviderSubscription], deduplicating in-flight requests and
  /// updating existing subscriptions in place to prevent duplicates.
  Future<Subscription> syncSession(AndroidMosaicSession session) {
    final directToken = session.directToken.trim();
    if (directToken.isEmpty) {
      throw const FormatException('Некорректный токен сессии MosaicVPN.');
    }

    final subscriptionUrl = normalizeSubscriptionUrl(session);
    final providerId = session.providerId?.trim().isNotEmpty == true
        ? session.providerId!.trim()
        : 'mosaicvpn';
    final providerAccountId =
        session.providerAccountId?.trim().isNotEmpty == true
            ? session.providerAccountId!.trim()
            : (session.username?.trim().isNotEmpty == true
                ? session.username!.trim()
                : (directToken.isNotEmpty ? directToken : 'mosaicvpn-default'));
    final subscriptionName =
        session.subscriptionName?.trim().isNotEmpty == true
            ? session.subscriptionName!.trim()
            : 'MosaicVPN';

    final dedupeKey = '$providerId:$providerAccountId:$subscriptionUrl';
    if (_inFlight.containsKey(dedupeKey)) {
      return _inFlight[dedupeKey]!;
    }

    final future = _doSync(
      providerId: providerId,
      providerAccountId: providerAccountId,
      subscriptionName: subscriptionName,
      subscriptionUrl: subscriptionUrl,
      session: session,
      directToken: directToken,
    );
    _inFlight[dedupeKey] = future;
    return future.whenComplete(() => _inFlight.remove(dedupeKey));
  }

  Future<Subscription> _doSync({
    required String providerId,
    required String providerAccountId,
    required String subscriptionName,
    required String subscriptionUrl,
    required AndroidMosaicSession session,
    required String directToken,
  }) async {
    try {
      return await api.enrollProviderSubscription(
        providerId: providerId,
        providerAccountId: providerAccountId,
        subscriptionName: subscriptionName,
        subscriptionUrl: subscriptionUrl,
        sessionToken: session.sessionToken?.trim(),
        directToken: directToken,
        username: session.username?.trim(),
      );
    } on FormatException {
      // Fallback for non-Mosaic provider URLs to standard addSubscription
      return await api.addSubscription(
        subscriptionName,
        subscriptionUrl,
        autoRefresh: true,
      );
    }
  }

  /// Invalidates all providers that depend on account authorization, subscription
  /// routes, server manifests, and payment states.
  static void invalidateDependentProviders(
      void Function(ProviderOrFamily) invalidate) {
    invalidate(androidMosaicSessionProvider);
    invalidate(billingProfileProvider);
    invalidate(unifiedAccountProvider);
    invalidate(subscriptionsProvider);
    invalidate(mosaicManifestProvider);
    invalidate(serversProvider);
    invalidate(serverGroupsProvider);
  }
}

/// Provider for [AccountSyncService], overridable in tests.
final accountSyncServiceProvider = Provider<AccountSyncService>((ref) {
  final api = ref.watch(daemonApiProvider);
  return AccountSyncService(api: api);
});
