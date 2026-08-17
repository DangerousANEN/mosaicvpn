import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';

final unifiedAccountProvider = FutureProvider<UnifiedAccount?>((ref) async {
  // Android resolves this through its hosted, Keystore-backed account facade;
  // desktop resolves through mosaicd. The screen intentionally stays shared.
  return ref.watch(daemonApiProvider).getUnifiedAccount();
});

class UnifiedAccountPanel extends ConsumerWidget {
  final UnifiedAccount account;
  const UnifiedAccountPanel({super.key, required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final frozen = account.isFrozen;
    final attention = account.needsFunds;
    final tint = frozen
        ? c.warning
        : attention
            ? c.danger
            : c.success;
    final status = frozen
        ? 'Доступ на паузе'
        : attention
            ? 'Нужно пополнить баланс'
            : 'Доступ активен';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
            const SizedBox(width: 9),
            Expanded(
                child: Text(status,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16))),
            Icon(Icons.shield_outlined, color: tint),
          ]),
          const SizedBox(height: 18),
          Text('Баланс', style: TextStyle(color: c.textMuted, fontSize: 12)),
          const SizedBox(height: 3),
          Text('${account.balanceRub.toStringAsFixed(2)} ₽',
              style: TextStyle(
                  color: c.textPrimary,
                  fontFamily: AtlasTheme.serifFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 34)),
          const SizedBox(height: 4),
          Text(
              'Списание: ${account.pricePerDayRub.toStringAsFixed(account.pricePerDayRub % 1 == 0 ? 0 : 2)} ₽ в сутки · ${account.timezone == 'Europe/Moscow' ? 'по Москве' : account.timezone}',
              style: TextStyle(color: c.textSecondary, fontSize: 12)),
          if (account.expiresAt != null) ...[
            const SizedBox(height: 8),
            Text(
                'Доступ до ${_dateTime(account.expiresAt!)} · осталось ${account.daysLeft} дн.',
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
          ] else if (account.trialEndsAt != null) ...[
            const SizedBox(height: 8),
            Text('Пробный период до ${_date(account.trialEndsAt!)}',
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
          ],
          if (account.nextChargeEstimateAt != null) ...[
            const SizedBox(height: 4),
            Text(
                'Ориентировочное списание: ${_dateTime(account.nextChargeEstimateAt!)}',
                style: TextStyle(color: c.textMuted, fontSize: 11)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
              onPressed: () => _openCheckout(context, ref),
              icon: const Icon(Icons.add_card_outlined),
              label: const Text('Пополнить'),
            )),
            const SizedBox(width: 10),
            Expanded(
                child: OutlinedButton.icon(
              onPressed: () => _toggleAccess(context, ref),
              icon:
                  Icon(frozen ? Icons.play_arrow_rounded : Icons.pause_rounded),
              label: Text(frozen ? 'Возобновить' : 'На паузу'),
            )),
          ]),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _rotateLink(context, ref),
            icon: const Icon(Icons.key_outlined, size: 18),
            label: const Text('Подписочная ссылка и безопасность'),
          ),
          const SizedBox(height: 6),
          _SubscriptionOverview(account: account),
        ],
      ),
    );
  }

  static String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

  static String _dateTime(DateTime value) =>
      '${_date(value)} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  Future<void> _toggleAccess(BuildContext context, WidgetRef ref) async {
    final frozen = account.isFrozen;
    final action = frozen ? 'возобновить доступ' : 'поставить доступ на паузу';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(
                  frozen ? 'Возобновить доступ?' : 'Приостановить доступ?'),
              content: Text(frozen
                  ? 'Ежедневные списания снова начнутся, когда доступ будет активен.'
                  : 'Подключение временно отключится, а ежедневные списания остановятся. Баланс сохранится.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(frozen ? 'Возобновить' : 'Приостановить'))
              ],
            ));
    if (accepted != true || !context.mounted) return;
    try {
      final api = ref.read(daemonApiProvider);
      if (frozen) {
        await api.unfreezeAccount();
      } else {
        await api.freezeAccount();
      }
      if (!context.mounted) return;
      ref.invalidate(unifiedAccountProvider);
      _notice(
          context,
          frozen
              ? 'Доступ возобновлён.'
              : 'Доступ на паузе. Списания остановлены.');
    } catch (_) {
      if (!context.mounted) return;
      _notice(context,
          'Не удалось $action. Проверьте соединение и попробуйте ещё раз.',
          error: true);
    }
  }

  Future<void> _openCheckout(BuildContext context, WidgetRef ref) async {
    final api = ref.read(daemonApiProvider);
    List<CheckoutProviderOption> providers;
    try {
      providers = await api.getCheckoutOptions();
    } catch (_) {
      if (context.mounted) {
        _notice(context, 'Способы оплаты временно недоступны.', error: true);
      }
      return;
    }
    providers = providers.where((p) => p.available).toList();
    if (providers.isEmpty) {
      if (context.mounted) {
        _notice(context, 'Сейчас нет доступных способов оплаты.', error: true);
      }
      return;
    }
    if (!context.mounted) return;
    final result = await showModalBottomSheet<
        ({int amount, CheckoutProviderOption provider})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _CheckoutSheet(providers: providers),
    );
    if (result == null || !context.mounted) return;
    try {
      final checkout = await api.createCheckout(
          amountRub: result.amount, provider: result.provider.id);
      if (!context.mounted) return;
      final opened = await launchUrl(checkout.checkoutUrl,
          mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        _notice(context, 'Не удалось открыть оплату. Попробуйте ещё раз.',
            error: true);
      }
    } catch (_) {
      if (context.mounted) {
        _notice(context, 'Не удалось создать счёт. Попробуйте позже.',
            error: true);
      }
    }
  }

  Future<void> _rotateLink(BuildContext context, WidgetRef ref) async {
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Перевыпустить ссылку?'),
              content: const Text(
                  'Используйте это, если ссылка попала посторонним. Старая ссылка и старые данные подключения перестанут работать. Вам понадобится добавить новую ссылку в приложение заново.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Перевыпустить'))
              ],
            ));
    if (accepted != true || !context.mounted) return;
    try {
      final link = await ref.read(daemonApiProvider).rotateSubscriptionLink();
      if (!context.mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Новая ссылка готова'),
                content: SelectableText(link.subscriptionUrl.toString()),
                actions: [
                  TextButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(
                            text: link.subscriptionUrl.toString()));
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('Скопировать')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Готово')),
                ],
              ));
      ref.invalidate(unifiedAccountProvider);
    } catch (_) {
      if (context.mounted) {
        _notice(context,
            'Не удалось перевыпустить ссылку. Повторите через несколько минут.',
            error: true);
      }
    }
  }

  static void _notice(BuildContext context, String message,
      {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? ThemeColors.of(context).danger : null));
  }
}

class _SubscriptionOverview extends StatelessWidget {
  final UnifiedAccount account;
  const _SubscriptionOverview({required this.account});

  static String _bytes(int value) {
    if (value <= 0) return '0 Б';
    const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final trafficRatio = account.hasTrafficLimit
        ? (account.trafficUsedBytes / account.trafficLimitBytes).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      padding: const EdgeInsets.only(top: 16),
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: c.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Статистика подписки',
            style:
                TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _MetricChip(
              label: 'Использовано', value: _bytes(account.trafficUsedBytes)),
          _MetricChip(
              label: 'За всё время',
              value: _bytes(account.lifetimeTrafficBytes)),
          _MetricChip(
              label: 'Устройства',
              value: account.deviceLimit > 0
                  ? '${account.devices.length}/${account.deviceLimit}'
                  : '${account.devices.length}'),
          if (account.statistics.lastSyncAt != null)
            _MetricChip(
                label: 'Синхронизация',
                value: _date(account.statistics.lastSyncAt!)),
        ]),
        if (account.hasTrafficLimit) ...[
          const SizedBox(height: 12),
          ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                  value: trafficRatio,
                  minHeight: 7,
                  color: c.accent,
                  backgroundColor: c.bgChild)),
          const SizedBox(height: 5),
          Text(
              '${_bytes(account.trafficUsedBytes)} из ${_bytes(account.trafficLimitBytes)}',
              style: TextStyle(color: c.textMuted, fontSize: 11)),
        ],
        const SizedBox(height: 16),
        Text('Устройства',
            style:
                TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (account.devices.isEmpty)
          Text(
              'Провайдер пока не передал список устройств. Лимит: ${account.deviceLimit > 0 ? account.deviceLimit : 'не указан'}.',
              style: TextStyle(color: c.textSecondary, fontSize: 12))
        else
          ...account.devices.map((device) => Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(children: [
                Icon(Icons.devices_other_outlined,
                    size: 17, color: c.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(device.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textPrimary, fontSize: 12))),
                if (device.platform.isNotEmpty)
                  Text(device.platform,
                      style: TextStyle(color: c.textMuted, fontSize: 11)),
              ]))),
      ]),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 112),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: c.bgChild, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: c.textMuted, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _CheckoutSheet extends StatefulWidget {
  final List<CheckoutProviderOption> providers;
  const _CheckoutSheet({required this.providers});
  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  late CheckoutProviderOption provider = widget.providers.first;
  late final TextEditingController amount =
      TextEditingController(text: '${provider.minAmountRub}');
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return SafeArea(
        child: Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Пополнение баланса',
                style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 24)),
            const SizedBox(height: 7),
            Text(
                'Укажите сумму от ${provider.minAmountRub} до ${provider.maxAmountRub} ₽. Средства зачислятся автоматически.',
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
            const SizedBox(height: 16),
            DropdownButtonFormField<CheckoutProviderOption>(
                initialValue: provider,
                items: widget.providers
                    .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.title)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      provider = value;
                      if (int.tryParse(amount.text) == null) {
                        amount.text = '${value.minAmountRub}';
                      }
                    });
                  }
                },
                decoration: const InputDecoration(labelText: 'Способ оплаты')),
            const SizedBox(height: 12),
            TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                    labelText: 'Сумма, ₽',
                    prefixIcon: Icon(Icons.account_balance_wallet_outlined))),
            const SizedBox(height: 16),
            SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: () {
                      final value = int.tryParse(amount.text) ?? 0;
                      if (value < provider.minAmountRub ||
                          value > provider.maxAmountRub) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(
                                'Введите сумму от ${provider.minAmountRub} до ${provider.maxAmountRub} ₽.')));
                        return;
                      }
                      Navigator.pop(
                          context, (amount: value, provider: provider));
                    },
                    child: const Text('Продолжить к оплате'))),
          ]),
    ));
  }
}
