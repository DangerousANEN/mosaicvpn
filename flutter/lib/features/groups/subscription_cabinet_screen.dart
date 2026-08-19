import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/models.dart';
import '../../core/platform/app_platform.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/android_mosaic_account_service.dart';
import '../../core/theme/atlas_theme.dart';
import '../account/unified_account_panel.dart';

final subscriptionCabinetPaymentsProvider = FutureProvider.autoDispose
    .family<List<PaymentEntry>, Subscription>((ref, subscription) async {
  if (AppPlatform.isAndroid) {
    return AndroidMosaicAccountService.instance
        .getPaymentHistory(subscriptionID: subscription.id);
  }
  return ref.watch(daemonApiProvider).getPaymentHistory();
});

final subscriptionCabinetAccountProvider = FutureProvider.autoDispose
    .family<UnifiedAccount?, Subscription>((ref, subscription) async {
  if (AppPlatform.isAndroid) {
    return AndroidMosaicAccountService.instance
        .getUnifiedAccount(subscriptionID: subscription.id);
  }
  return ref.watch(daemonApiProvider).getUnifiedAccount();
});

final subscriptionCabinetBindingProvider = FutureProvider.autoDispose
    .family<bool, Subscription>((ref, subscription) async {
  if (AppPlatform.isAndroid) {
    return AndroidMosaicAccountService.instance.hasBinding(subscription.id);
  }
  return (await ref.watch(daemonApiProvider).getUnifiedAccount()) != null;
});

/// Safe base metadata exists independently of an account session and is keyed
/// by the already-stored MosaicVPN subscription capability URL.
final mosaicBaseProfileProvider =
    FutureProvider.family<SubscriptionBaseProfile, Subscription>(
  (ref, subscription) => AndroidMosaicAccountService.instance
      .getSubscriptionBaseProfile(subscription.url),
);

/// Cabinet attached to one provider subscription rather than to a global
/// application profile. A subscription can expose a cabinet only when its
/// provider has an authenticated capability adapter.
class SubscriptionCabinetScreen extends ConsumerWidget {
  const SubscriptionCabinetScreen({super.key, required this.subscription});

  final Subscription subscription;

  bool get _isMosaicCabinet {
    final uri = Uri.tryParse(subscription.url.trim());
    return subscription.providerId == 'mosaicvpn' ||
        (uri != null &&
            uri.isScheme('https') &&
            uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
            uri.pathSegments.isNotEmpty);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ThemeColors.of(context);
    final baseProfile = _isMosaicCabinet
        ? ref.watch(mosaicBaseProfileProvider(subscription))
        : null;
    final account = _isMosaicCabinet
        ? ref.watch(subscriptionCabinetAccountProvider(subscription))
        : null;
    final binding = _isMosaicCabinet
        ? ref.watch(subscriptionCabinetBindingProvider(subscription))
        : null;
    final payments = _isMosaicCabinet
        ? ref.watch(subscriptionCabinetPaymentsProvider(subscription))
        : null;
    final title =
        subscription.name.isEmpty ? 'Кабинет подписки' : subscription.name;

    return Scaffold(
      backgroundColor: colors.bgBase,
      appBar: AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: () async {
          if (_isMosaicCabinet) {
            ref.invalidate(mosaicBaseProfileProvider(subscription));
            ref.invalidate(subscriptionCabinetAccountProvider(subscription));
            ref.invalidate(subscriptionCabinetBindingProvider(subscription));
            ref.invalidate(subscriptionCabinetPaymentsProvider(subscription));
            await ref.read(mosaicBaseProfileProvider(subscription).future);
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            _CabinetHeader(subscription: subscription),
            const SizedBox(height: 14),
            if (_isMosaicCabinet) ...[
              baseProfile!.when(
                loading: () => const _PanelLoading(),
                error: (_, __) => const _BaseProfileUnavailable(),
                data: (profile) => _BaseSubscriptionProfile(profile: profile),
              ),
              const SizedBox(height: 14),
              account!.when(
                loading: () => const _PanelLoading(),
                error: (_, __) => _CabinetUnavailable(
                  subscription: subscription,
                  binding: binding?.valueOrNull == true,
                ),
                data: (value) => value == null
                    ? _CabinetUnavailable(
                        subscription: subscription,
                        binding: binding?.valueOrNull == true,
                      )
                    : UnifiedAccountPanel(account: value),
              ),
              if (account.valueOrNull != null) ...[
                const SizedBox(height: 14),
                payments!.when(
                  loading: () => const _PanelLoading(),
                  error: (_, __) => const _PaymentHistoryUnavailable(),
                  data: (rows) => _PaymentHistory(rows: rows),
                ),
              ],
            ] else
              _GenericSubscriptionProfile(subscription: subscription),
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

class _BaseSubscriptionProfile extends StatelessWidget {
  const _BaseSubscriptionProfile({required this.profile});

  final SubscriptionBaseProfile profile;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final expires = profile.expiresAt == null
        ? 'не указано'
        : '${profile.expiresAt!.toLocal()}'.split('.').first;
    final traffic = profile.hasTrafficLimit
        ? '${_formatBytes(profile.trafficUsedBytes)} / ${_formatBytes(profile.trafficLimitBytes)}'
        : '${_formatBytes(profile.trafficUsedBytes)} / без лимита';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AtlasTheme.accent.withValues(alpha: .38)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.info_outline, color: AtlasTheme.accent),
          const SizedBox(width: 8),
          Text('Информация о подписке',
              style:
                  TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),
        _ProfileFact(
            label: 'Статус',
            value: profile.status,
            valueColor: profile.status == 'active' ? c.success : c.warning),
        _ProfileFact(label: 'Осталось дней', value: '${profile.daysLeft}'),
        _ProfileFact(label: 'Действует до', value: expires),
        _ProfileFact(label: 'Трафик', value: traffic),
        _ProfileFact(
            label: 'Всего использовано',
            value: _formatBytes(profile.lifetimeTrafficBytes)),
        _ProfileFact(
            label: 'Лимит устройств',
            value: profile.deviceLimit > 0
                ? '${profile.deviceLimit}'
                : 'не указан'),
        const SizedBox(height: 4),
        Text(
            'Эти сведения доступны по вашей ссылке подписки. Они не раскрывают серверы, устройства, платежи или данные кабинета.',
            style:
                TextStyle(color: c.textSecondary, fontSize: 12, height: 1.35)),
      ]),
    );
  }
}

class _BaseProfileUnavailable extends StatelessWidget {
  const _BaseProfileUnavailable();

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
      child: Text(
          'Не удалось обновить базовые сведения подписки. Проверьте ссылку и повторите обновление.',
          style: TextStyle(color: c.textSecondary, fontSize: 12)),
    );
  }
}

String _formatBytes(int value) {
  if (value < 1024) return '$value Б';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} КБ';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}

class _CabinetUnavailable extends ConsumerStatefulWidget {
  const _CabinetUnavailable({
    required this.subscription,
    required this.binding,
  });

  final Subscription subscription;
  final bool binding;

  @override
  ConsumerState<_CabinetUnavailable> createState() =>
      _CabinetUnavailableState();
}

class _CabinetUnavailableState extends ConsumerState<_CabinetUnavailable> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _openWebsiteCabinet() async {
    final uri = Uri.parse('https://sub.zxc1x1.ru/cabinet.html');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Не удалось открыть сайт кабинета.'),
      backgroundColor: ThemeColors.of(context).danger,
    ));
  }

  Future<void> _attachByCode() async {
    try {
      setState(() => _busy = true);
      await ref.read(daemonApiProvider).redeemLinkCode(
            _code.text,
            subscriptionId: widget.subscription.id,
          );
      if (!mounted) return;
      _code.clear();
      ref.invalidate(subscriptionCabinetBindingProvider(widget.subscription));
      ref.invalidate(subscriptionCabinetAccountProvider(widget.subscription));
      ref.invalidate(subscriptionCabinetPaymentsProvider(widget.subscription));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Кабинет подключён к выбранной подписке.'),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Не удалось подключить кабинет: $error'),
        backgroundColor: ThemeColors.of(context).danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final bindingText = widget.binding
        ? 'Кабинет уже связан с этой подпиской, но его данные временно не удалось обновить. Потяните экран вниз, чтобы повторить запрос.'
        : 'Базовые срок, статус и трафик уже показаны выше. Откройте сайт кабинета, войдите в нужный профиль и получите одноразовый код. Тот же код можно получить командой /link в привязанном Telegram. После ввода здесь откроются баланс, пополнение, устройства, платежи, заморозка и ротация ссылки.';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(widget.binding ? Icons.sync_problem_outlined : Icons.lock_outline,
            color: c.textSecondary),
        const SizedBox(height: 10),
        Text(
            widget.binding
                ? 'Кабинет временно недоступен'
                : 'Подключите кабинет MosaicVPN',
            style:
                TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(bindingText,
            style: TextStyle(color: c.textSecondary, fontSize: 12)),
        if (!widget.binding) ...[
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _openWebsiteCabinet,
              icon: const Icon(Icons.open_in_browser_outlined),
              label: const Text('Открыть сайт и получить код'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Код из сайта или Telegram',
              hintText: 'AB23CD45',
              helperText: 'Код действует 10 минут и используется один раз.',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _attachByCode,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.key_outlined),
              label: Text(_busy ? 'Подключаем…' : 'Подключить профиль по коду'),
            ),
          ),
        ],
      ]),
    );
  }
}

class _GenericSubscriptionProfile extends StatelessWidget {
  const _GenericSubscriptionProfile({required this.subscription});

  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final refreshed = subscription.lastFetched.millisecondsSinceEpoch == 0
        ? 'ещё не обновлялась'
        : '${subscription.lastFetched.toLocal()}'.split('.').first;
    final kind = subscription.isProviderSource
        ? 'Профиль поставщика'
        : 'Импортированная подписка';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.info_outline, color: AtlasTheme.accent),
          const SizedBox(width: 8),
          Text(kind,
              style:
                  TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 14),
        _ProfileFact(label: 'Маршрутов', value: '${subscription.serverCount}'),
        _ProfileFact(label: 'Последнее обновление', value: refreshed),
        _ProfileFact(
          label: 'Статус',
          value: subscription.hasError
              ? subscription.lastError
              : 'Источник доступен на этом устройстве',
          valueColor: subscription.hasError ? c.danger : c.success,
        ),
        const SizedBox(height: 14),
        Text(
          'Этот сервис пока не объявил совместимый кабинет. Когда поставщик передаст поддерживаемые возможности, здесь появятся данные доступа, устройства и платежи без изменения самой подписки.',
          style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.35),
        ),
      ]),
    );
  }
}

class _ProfileFact extends StatelessWidget {
  const _ProfileFact({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 148,
          child: Text(label,
              style: TextStyle(color: c.textSecondary, fontSize: 12)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor ?? c.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
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
