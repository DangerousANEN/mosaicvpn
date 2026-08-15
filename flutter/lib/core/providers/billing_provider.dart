import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/daemon_api_base.dart';
import '../models/models.dart';
import '../platform/app_platform.dart';
import '../services/android_mosaic_account_service.dart';
import 'vpn_providers.dart';

/// Restores the Android device-scoped hosted account session. This contains
/// only a direct-feed credential stored in Android Keystore, never mock data.
final androidMosaicSessionProvider =
    FutureProvider.autoDispose<AndroidMosaicSession?>((ref) async {
  if (!AppPlatform.isAndroid) return null;
  return AndroidMosaicAccountService.instance.restoreSession();
});

/// Provider fetching the current user's [BillingProfile].
final billingProfileProvider =
    FutureProvider.autoDispose<BillingProfile>((ref) async {
  if (AppPlatform.isAndroid) {
    final session = await ref.watch(androidMosaicSessionProvider.future);
    return BillingProfile(
      linked: session != null,
      username: session?.username ?? '',
      email: session?.username?.contains('@') == true ? session!.username! : '',
      status: session == null ? '' : 'active',
      description: session == null
          ? ''
          : 'Android device is linked to a MosaicVPN direct profile.',
    );
  }
  final api = ref.watch(daemonApiProvider);
  return api.getBillingProfile();
});

/// Family provider checking the status of a CryptoBot invoice by ID.
final activeTopupStatusProvider = FutureProvider.family
    .autoDispose<TopupStatusResponse, int>((ref, invoiceId) async {
  final api = ref.watch(daemonApiProvider);
  return api.getTopupStatus(invoiceId);
});

/// Notifier providing mutations for billing operations: link, unlink, topup, refresh.
class BillingNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;

  BillingNotifier(this._ref) : super(const AsyncData(null));

  DaemonApiBase get _api => _ref.read(daemonApiProvider);

  /// Invalidate and re-fetch the billing profile.
  Future<void> refreshProfile() async {
    _ref.invalidate(billingProfileProvider);
  }

  /// Link a Telegram account using telegramId and optional session token.
  Future<bool> linkAccount(int telegramId, {String? sessionToken}) async {
    state = const AsyncLoading();
    try {
      await _api.linkBillingAccount(telegramId, sessionToken: sessionToken);
      _ref.invalidate(billingProfileProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  /// Unlink the currently linked Telegram account.
  Future<bool> unlinkAccount() async {
    state = const AsyncLoading();
    try {
      await _api.unlinkBillingAccount();
      _ref.invalidate(billingProfileProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  /// Create a CryptoBot top-up invoice.
  Future<TopupResponse?> createTopup({
    required double amount,
    int? days,
    String? description,
  }) async {
    state = const AsyncLoading();
    try {
      final response = await _api.createTopup(
        amount: amount,
        days: days,
        description: description,
      );
      state = const AsyncData(null);
      return response;
    } catch (e, st) {
      state = AsyncError(e, st);
      return null;
    }
  }

  /// Check status of a top-up invoice and refresh profile if paid.
  Future<TopupStatusResponse?> checkTopupStatus(int invoiceId) async {
    try {
      final response = await _api.getTopupStatus(invoiceId);
      if (response.status == 'paid') {
        _ref.invalidate(billingProfileProvider);
      }
      return response;
    } catch (e) {
      return null;
    }
  }
}

/// Provider for [BillingNotifier].
final billingNotifierProvider =
    StateNotifierProvider.autoDispose<BillingNotifier, AsyncValue<void>>((ref) {
  return BillingNotifier(ref);
});
