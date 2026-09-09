import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/external_launcher.dart';
import '../../core/models/subscription.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/android_mosaic_account_service.dart';
import '../../core/theme/atlas_theme.dart';

class AtlasOnboardingCard extends ConsumerStatefulWidget {
  final List<Subscription> subscriptions;
  final Subscription selectedSubscription;
  final ValueChanged<Subscription> onSubscriptionChanged;

  const AtlasOnboardingCard({
    super.key,
    required this.subscriptions,
    required this.selectedSubscription,
    required this.onSubscriptionChanged,
  });

  @override
  ConsumerState<AtlasOnboardingCard> createState() =>
      _AtlasOnboardingCardState();
}

class _AtlasOnboardingCardState extends ConsumerState<AtlasOnboardingCard> {
  String? _clipboardCandidate;

  @override
  void initState() {
    super.initState();
    _checkClipboard();
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.startsWith('http://') ||
          text.startsWith('https://') ||
          text.startsWith('vless://') ||
          text.startsWith('vmess://') ||
          text.startsWith('ss://')) {
        if (mounted) setState(() => _clipboardCandidate = text);
      }
    } catch (_) {}
  }

  Future<void> _addCandidate(String url) async {
    final api = ref.read(daemonApiProvider);
    try {
      final trimmed = url.trim();
      if (RegExp(r'^[A-Za-z0-9_-]{8}$').hasMatch(trimmed)) {
        final session = await AndroidMosaicAccountService.instance.redeemTelegramCode(trimmed);
        final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
            ? session.subscriptionUrl!.trim()
            : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';
        await api.addSubscription('Моя подписка', subUrl, autoRefresh: true);
      } else if (trimmed.startsWith('mosaicvpn://')) {
        final uri = Uri.tryParse(trimmed);
        if (uri != null) {
          await AndroidMosaicAccountService.instance.completeEnrollmentCallback(uri);
        }
      } else {
        await api.addSubscription('Моя подписка', trimmed, autoRefresh: true);
      }
      ref.invalidate(subscriptionsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Подписка успешно добавлена!'),
            backgroundColor: AtlasTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка добавления: $e'),
            backgroundColor: AtlasTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showManualDialog() async {
    final controller =
        TextEditingController(text: _clipboardCandidate ?? '');
    final formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = ThemeColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.bgElevated,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Добавить подписку',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              style: TextStyle(color: c.textPrimary, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: 'https://... или vless://...',
                hintStyle: TextStyle(color: c.textMuted),
                filled: true,
                fillColor: c.bgCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Введите ссылку' : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Отмена', style: TextStyle(color: c.textMuted)),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() == true) {
                  Navigator.of(ctx).pop();
                  _addCandidate(controller.text.trim());
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AtlasTheme.accent,
                foregroundColor: AtlasTheme.onAccent,
              ),
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openTelegramBot() async {
    await ExternalLauncher.openTelegram('mosaicvpnbot');
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: AtlasTheme.accent.withValues(alpha: .12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AtlasTheme.accent.withValues(alpha: .3),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.explore_outlined,
                      size: 46,
                      color: AtlasTheme.accent,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'MOSAIC VPN',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AtlasTheme.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Безопасный и свободный интернет',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Подключите подписку для автоматической настройки защищённого соединения без блокировок и замедлений.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
              const SizedBox(height: 24),
              if (_clipboardCandidate != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.success.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.success.withValues(alpha: .4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.content_paste_rounded,
                              size: 18, color: c.success),
                          const SizedBox(width: 8),
                          Text(
                            'Ссылка найдена в буфере обмена',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: c.success,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _clipboardCandidate!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () =>
                              _addCandidate(_clipboardCandidate!),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.success,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Добавить в 1 клик'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              ElevatedButton.icon(
                onPressed: _showManualDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AtlasTheme.accent,
                  foregroundColor: AtlasTheme.onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.add_link_rounded, size: 20),
                label: const Text(
                  'Вставить ссылку подписки',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _openTelegramBot,
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: c.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text(
                  'Получить ключ в Telegram',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lightbulb_outline_rounded,
                        size: 20, color: AtlasTheme.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Российские банки и Госуслуги продолжат работать напрямую без отключения VPN.',
                        style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
