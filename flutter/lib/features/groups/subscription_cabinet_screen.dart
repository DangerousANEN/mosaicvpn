import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
import '../account/unified_account_panel.dart';

final subscriptionCabinetPaymentsProvider =
    FutureProvider.autoDispose<List<PaymentEntry>>((ref) async {
  return ref.watch(daemonApiProvider).getPaymentHistory();
});

/// Cabinet attached to one provider subscription rather than to a global
/// application profile. A subscription can expose a cabinet only when its
/// provider has an authenticated capability adapter.
class SubscriptionCabinetScreen extends ConsumerWidget {
  const SubscriptionCabinetScreen({super.key, required this.subscription});

  final Subscription subscription;

  bool get _isMosaicCabinet =>
      subscription.isProviderSource && subscription.providerId == 'mosaicvpn';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ThemeColors.of(context);
    final account = ref.watch(unifiedAccountProvider);
    final payments = ref.watch(subscriptionCabinetPaymentsProvider);
    final title =
        subscription.name.isEmpty ? 'Кабинет подписки' : subscription.name;

    return Scaffold(
      backgroundColor: colors.bgBase,
      appBar: AppBar(title: Text(title)),
      body: !_isMosaicCabinet
          ? _UnsupportedCabinet(sourceName: title)
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(unifiedAccountProvider);
                ref.invalidate(subscriptionCabinetPaymentsProvider);
                await ref.read(unifiedAccountProvider.future);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                children: [
                  _CabinetHeader(subscription: subscription),
                  const SizedBox(height: 14),
                  account.when(
                    loading: () => const _PanelLoading(),
                    error: (_, __) => const _CabinetUnavailable(),
                    data: (value) => value == null
                        ? const _CabinetUnavailable()
                        : UnifiedAccountPanel(account: value),
                  ),
                  const SizedBox(height: 14),
                  payments.when(
                    loading: () => const _PanelLoading(),
                    error: (_, __) => const _PaymentHistoryUnavailable(),
                    data: (rows) => _PaymentHistory(rows: rows),
                  ),
                ],
              ),
            ),
    );
  }
}

class _CabinetHeader extends StatelessWidget {
  const _CabinetHeader({required this.subscription});
  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AtlasTheme.accent.withValues(alpha: .4)),
      ),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AtlasTheme.accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(Icons.shield_outlined, color: AtlasTheme.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(subscription.name.isEmpty ? 'MosaicVPN' : subscription.name,
                style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            const SizedBox(height: 3),
            Text(
                'Кабинет этой подписки: доступ, платежи, устройства и безопасность.',
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _PanelLoading extends StatelessWidget {
  const _PanelLoading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _CabinetUnavailable extends StatelessWidget {
  const _CabinetUnavailable();
  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline, color: c.textSecondary),
        const SizedBox(height: 10),
        Text('Подключите кабинет MosaicVPN',
            style:
                TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(
            'Войдите в MosaicVPN через сайт или Telegram-код на экране доступа. Затем вернитесь к этой подписке.',
            style: TextStyle(color: c.textSecondary, fontSize: 12)),
      ]),
    );
  }
}

class _UnsupportedCabinet extends StatelessWidget {
  const _UnsupportedCabinet({required this.sourceName});
  final String sourceName;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.info_outline, color: c.textSecondary, size: 30),
          const SizedBox(height: 12),
          Text('Кабинет пока не подключён',
              style:
                  TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              '$sourceName передаёт маршруты, но не объявил совместимый кабинет. Доступные данные подписки будут отображаться в карточке источника.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 13)),
        ]),
      ),
    );
  }
}

class _PaymentHistoryUnavailable extends StatelessWidget {
  const _PaymentHistoryUnavailable();
  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Text('История платежей временно недоступна.',
        style: TextStyle(color: c.textSecondary, fontSize: 12));
  }
}

class _PaymentHistory extends StatelessWidget {
  const _PaymentHistory({required this.rows});
  final List<PaymentEntry> rows;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('История пополнений',
            style:
                TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          Text('Платежей пока нет.',
              style: TextStyle(color: c.textSecondary, fontSize: 12))
        else
          ...rows.take(12).map((payment) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 17, color: c.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        payment.description.isEmpty
                            ? payment.status
                            : payment.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textPrimary, fontSize: 12)),
                  ),
                  Text('${payment.amount.toStringAsFixed(0)} ₽',
                      style: TextStyle(
                          color: c.success,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ]),
              )),
      ]),
    );
  }
}
