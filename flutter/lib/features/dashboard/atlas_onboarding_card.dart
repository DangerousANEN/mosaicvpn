import 'dart:math';

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

  /// Guards the primary CTA against double taps while signup is in flight.
  bool _busy = false;

  /// Human-readable failure of the last signup attempt, shown inline so the
  /// user gets an explanation without leaving this screen.
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkClipboard();
  }

  /// Creates an account in-app and persists its subscription.
  ///
  /// This is the whole point of the screen: a user who installed the app but
  /// has no subscription yet should be ONE tap away from a working tunnel,
  /// not sent to a browser to register and then asked to paste a link back.
  /// The default credentials are generated locally, so the user does not even
  /// have to invent a password at this stage -- the account can be claimed
  /// properly (own email/password) later from the cabinet.
  Future<void> _startFreeInApp() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = AndroidMosaicAccountService.instance;
    final api = ref.read(daemonApiProvider);
    try {
      final credentials = _generateTrialCredentials();
      final session = await account.registerWithEmail(
          credentials.$1, credentials.$2);
      final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
          ? session.subscriptionUrl!.trim()
          : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';
      await api.addSubscription('Моя подписка', subUrl, autoRefresh: true);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Доступ на 3 дня активирован. Выберите маршрут и подключитесь.'),
          backgroundColor: AtlasTheme.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final raw = error.toString().replaceFirst('Bad state: ', '').trim();
      setState(() {
        _busy = false;
        _error = raw.contains('502') || raw.isEmpty
            ? 'Сервис временно недоступен. Попробуйте ещё раз через минуту.'
            : raw;
      });
    }
  }

  /// Local email/password pair for an instant trial account: random, unique,
  /// and never shown to the user (they can set real credentials later).
  (String, String) _generateTrialCredentials() {
    final random = Random.secure();
    final suffix = List.generate(12, (_) => random.nextInt(36))
        .map((value) => value.toRadixString(36))
        .join();
    final password = List.generate(24, (_) => random.nextInt(36))
        .map((value) => value.toRadixString(36))
        .join();
    return ('mosaic-$suffix@mosaic-trial.app', password);
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

  /// Bottom sheet with the manual access doors (existing subscription link or
  /// a Telegram key). Kept off the main screen so a newcomer is not asked to
  /// choose between three ways of getting access they do not understand yet.
  Future<void> _openAccessOptions() async {
    final c = ThemeColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgCard,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Добавить доступ',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.add_link_rounded, color: AtlasTheme.accent),
                title: Text('Вставить ссылку подписки',
                    style: TextStyle(color: c.textPrimary, fontSize: 14.5)),
                subtitle: Text('Ссылка вида https://… из письма или бота',
                    style: TextStyle(color: c.textMuted, fontSize: 12)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showManualDialog();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.send_rounded, color: AtlasTheme.accent),
                title: Text('Получить доступ в Telegram',
                    style: TextStyle(color: c.textPrimary, fontSize: 14.5)),
                subtitle: Text('Бот выдаст код, приложение его подхватит',
                    style: TextStyle(color: c.textMuted, fontSize: 12)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openTelegramBot();
                },
              ),
              if (_clipboardCandidate != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.content_paste_rounded, color: c.success),
                  title: Text('Использовать ссылку из буфера',
                      style: TextStyle(color: c.textPrimary, fontSize: 14.5)),
                  subtitle: Text(_clipboardCandidate!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textMuted, fontSize: 11.5)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _addCandidate(_clipboardCandidate!);
                  },
                ),
            ],
          ),
        ),
      ),
    );
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
    await ExternalLauncher.openTelegram('mosaicvpnbot', startParam: 'app');
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
                'Подписка настраивает защищённое соединение автоматически: цифровая приватность, раздельное туннелирование и стабильная сеть.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
              const SizedBox(height: 24),
              // PRIMARY: the shortest path to a working tunnel. One tap runs
              // the in-app signup, which grants the free trial and persists the
              // subscription, then lands the user on the connect screen. No
              // browser, no Telegram, no link to copy.
              Semantics(
                button: true,
                label: 'Начать бесплатно',
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _startFreeInApp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AtlasTheme.accent,
                    foregroundColor: AtlasTheme.onAccent,
                    disabledBackgroundColor:
                        AtlasTheme.accent.withValues(alpha: .5),
                    disabledForegroundColor: AtlasTheme.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AtlasTheme.onAccent),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 20),
                  label: const Text(
                    'Начать бесплатно',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Создаст аккаунт и подключит доступ на 3 дня. Карта не нужна.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: c.textMuted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AtlasTheme.error.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: AtlasTheme.error.withValues(alpha: .35)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 18, color: AtlasTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                              fontSize: 12.5, color: c.textPrimary, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Already have access somewhere else? Keep those doors open, but
              // visually secondary: the default path above is what a newcomer
              // should take.
              OutlinedButton.icon(
                onPressed: _busy ? null : _openAccessOptions,
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: c.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.key_rounded, size: 18),
                label: const Text(
                  'У меня уже есть доступ',
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
