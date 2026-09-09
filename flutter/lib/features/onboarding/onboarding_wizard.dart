import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/external_launcher.dart';

import '../../core/providers/vpn_providers.dart';
import '../../core/providers/routing_presets_provider.dart';
import '../../core/services/android_mosaic_account_service.dart';
import '../../core/services/ui_preferences_service.dart';
import '../../core/theme/atlas_theme.dart';

/// First-launch setup wizard in the Atlas Zen design language.
/// Calm, confident, guided experience for both non-technical users and gamers.
class OnboardingWizard extends ConsumerStatefulWidget {
  const OnboardingWizard({super.key, required this.onDone});

  /// Called after the wizard finishes (or is skipped) so the shell reveals
  /// the main navigation.
  final VoidCallback onDone;

  static const _kSeenKey = 'mosaic.onboarding_done.v1';

  /// Whether the wizard should appear for this install.
  static Future<bool> shouldShow() async {
    final storage = await SharedPreferences.getInstance();
    return !(storage.getBool(_kSeenKey) ?? false);
  }

  static Future<void> markDone() async {
    final storage = await SharedPreferences.getInstance();
    await storage.setBool(_kSeenKey, true);
  }

  @override
  ConsumerState<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends ConsumerState<OnboardingWizard> {
  int _step = 0;
  String _selectedMode = 'smart'; // 'smart', 'gamer', 'full'
  final TextEditingController _subUrlController = TextEditingController();
  bool _importing = false;
  String? _importError;

  @override
  void initState() {
    super.initState();
    _checkClipboardForSubscription();
  }

  @override
  void dispose() {
    _subUrlController.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardForSubscription() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.startsWith('http://') || text.startsWith('https://')) {
        if (text.contains('sub') || text.contains('vless') || text.contains('token')) {
          if (mounted && _subUrlController.text.isEmpty) {
            setState(() {
              _subUrlController.text = text;
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _applySelectedMode() async {
    final prefs = UiPreferencesService();
    if (_selectedMode == 'smart') {
      await prefs.writeBypassRussianSites(true);
      await prefs.writeAutoFailover(true);
      try {
        final presets = await ref.read(routingPresetsProvider.future);
        final rf = presets.firstWhere((p) => p.id == 'preset-rf-banks', orElse: () => presets.first);
        await applyRoutingPreset(ref, rf);
      } catch (_) {}
    } else if (_selectedMode == 'gamer') {
      await prefs.writeBypassRussianSites(true);
      await prefs.writeAutoFailover(false); // Gamer safety: never auto-switch during match
    } else {
      await prefs.writeBypassRussianSites(false);
      await prefs.writeAutoFailover(true);
      try {
        final presets = await ref.read(routingPresetsProvider.future);
        final gl = presets.firstWhere((p) => p.id == 'preset-global', orElse: () => presets.first);
        await applyRoutingPreset(ref, gl);
      } catch (_) {}
    }
  }

  Future<void> _finish() async {
    await _applySelectedMode();
    final url = _subUrlController.text.trim();
    if (url.isNotEmpty) {
      setState(() => _importing = true);
      try {
        if (RegExp(r'^[A-Za-z0-9_-]{8}$').hasMatch(url)) {
          // Direct 8-character pairing code from Telegram bot
          final session = await AndroidMosaicAccountService.instance.redeemTelegramCode(url);
          final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
              ? session.subscriptionUrl!.trim()
              : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';
          final api = ref.read(daemonApiProvider);
          await api.addSubscription('Основная подписка', subUrl, autoRefresh: true);
          ref.invalidate(subscriptionsProvider);
        } else if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('mosaicvpn://')) {
          if (url.startsWith('mosaicvpn://')) {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              await AndroidMosaicAccountService.instance.completeEnrollmentCallback(uri);
            }
          } else {
            final api = ref.read(daemonApiProvider);
            await api.addSubscription('Основная подписка', url, autoRefresh: true);
            ref.invalidate(subscriptionsProvider);
          }
        }
      } catch (e) {
        // Non-blocking import failure: proceed anyway
      }
    }
    await OnboardingWizard.markDone();
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: c.bgBase,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(c),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _buildCurrentStep(c),
                  ),
                ),
              ),
              _buildBottomControls(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(ThemeColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AtlasTheme.accent, AtlasTheme.accent.withValues(alpha: .7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.shield_rounded, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Text(
                'MosaicVPN',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                  letterSpacing: .3,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Step pills
          Row(
            children: List.generate(3, (index) {
              final active = index == _step;
              final passed = index < _step;
              return Container(
                margin: const EdgeInsets.only(left: 6),
                width: active ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active
                      ? AtlasTheme.accent
                      : passed
                          ? c.success
                          : c.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentStep(ThemeColors c) {
    switch (_step) {
      case 0:
        return _buildWelcomeStep(c);
      case 1:
        return _buildModeStep(c);
      case 2:
      default:
        return _buildSubscriptionStep(c);
    }
  }

  Widget _buildWelcomeStep(ThemeColors c) {
    return Column(
      key: const ValueKey(0),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AtlasTheme.accent.withValues(alpha: .12),
              border: Border.all(color: AtlasTheme.accent.withValues(alpha: .35), width: 2),
              boxShadow: [
                BoxShadow(
                  color: AtlasTheme.accent.withValues(alpha: .18),
                  blurRadius: 36,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(
              Icons.explore_rounded,
              size: 52,
              color: AtlasTheme.accent,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Свободный интернет\nбез ограничений',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: AtlasTheme.serifFamily,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Быстрый доступ к заблокированным ресурсам, защита приватности и стабильный пинг.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: c.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 28),
        _buildFeatureRow(
          c,
          icon: Icons.flash_on_rounded,
          iconColor: const Color(0xFFFBBF24),
          title: 'Максимальная скорость',
          desc: 'Магистральные каналы 1 Гбит/с без очередей и замедлений YouTube.',
        ),
        const SizedBox(height: 14),
        _buildFeatureRow(
          c,
          icon: Icons.account_balance_rounded,
          iconColor: const Color(0xFF60A5FA),
          title: 'Умный обход сайтов РФ',
          desc: 'Банки, Госуслуги и доставка работают напрямую без выключения VPN.',
        ),
        const SizedBox(height: 14),
        _buildFeatureRow(
          c,
          icon: Icons.lock_rounded,
          iconColor: c.success,
          title: 'Zero-Logs и приватность',
          desc: 'VLESS шифрование нового поколения. Ваш провайдер ничего не видит.',
        ),
      ],
    );
  }

  Widget _buildFeatureRow(
    ThemeColors c, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String desc,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border.withValues(alpha: .7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: c.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeStep(ThemeColors c) {
    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Режим работы',
          style: TextStyle(
            fontFamily: AtlasTheme.serifFamily,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Выберите, как VPN должен обрабатывать ваш трафик. Это можно изменить в любой момент.',
          style: TextStyle(fontSize: 13.5, color: c.textSecondary, height: 1.3),
        ),
        const SizedBox(height: 20),
        _buildModeCard(
          c,
          id: 'smart',
          tag: 'РЕКОМЕНДУЕТСЯ',
          tagColor: c.success,
          icon: Icons.auto_awesome_rounded,
          title: 'Умный обход РФ',
          subtitle:
              'Сайты банков, Госуслуг и сервисы зоны .RU открываются напрямую на максимальной скорости. Всё остальное защищено VPN.',
        ),
        const SizedBox(height: 12),
        _buildModeCard(
          c,
          id: 'gamer',
          tag: 'ДЛЯ ГЕЙМЕРОВ',
          tagColor: const Color(0xFFF59E0B),
          icon: Icons.sports_esports_rounded,
          title: 'Игровой режим',
          subtitle:
              'Фиксированный узел с минимальным пингом. Автосмена IP отключена, чтобы не разрывать активные матчи в CS2, Dota 2 и Discord.',
        ),
        const SizedBox(height: 12),
        _buildModeCard(
          c,
          id: 'full',
          tag: 'МАКСИМУМ',
          tagColor: AtlasTheme.accent,
          icon: Icons.shield_rounded,
          title: 'Полная изоляция',
          subtitle:
              '100% трафика всех приложений и браузеров направляется через зашифрованный туннель.',
        ),
      ],
    );
  }

  Widget _buildModeCard(
    ThemeColors c, {
    required String id,
    required String tag,
    required Color tagColor,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _selectedMode == id;
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: selected ? AtlasTheme.accent.withValues(alpha: .12) : c.bgCard,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _selectedMode = id),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? AtlasTheme.accent : c.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: (selected ? AtlasTheme.accent : tagColor).withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 18, color: selected ? AtlasTheme.accent : tagColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: tagColor.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: tagColor,
                          letterSpacing: .4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: c.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionStep(ThemeColors c) {
    return Column(
      key: const ValueKey(2),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Подключение подписки',
          style: TextStyle(
            fontFamily: AtlasTheme.serifFamily,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Вставьте персональную ссылку подписки или добавьте её позже.',
          style: TextStyle(fontSize: 13.5, color: c.textSecondary, height: 1.3),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ссылка на конфигурацию:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _subUrlController,
                decoration: InputDecoration(
                  hintText: 'Ссылка https://... или код из бота',
                  hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                  filled: true,
                  fillColor: c.bgBase,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AtlasTheme.accent, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  suffixIcon: IconButton(
                    icon: Icon(Icons.paste_rounded, size: 18, color: c.textMuted),
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text case final text? when text.isNotEmpty) {
                        setState(() => _subUrlController.text = text.trim());
                      }
                    },
                    tooltip: 'Вставить из буфера',
                  ),
                ),
                style: TextStyle(color: c.textPrimary, fontSize: 13.5),
              ),
              if (_importError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _importError!,
                  style: const TextStyle(color: AtlasTheme.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            await ExternalLauncher.openTelegram('mosaicvpnbot');
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: c.textPrimary,
            side: BorderSide(color: c.border),
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.send_rounded, size: 18, color: AtlasTheme.accent),
          label: const Text(
            'Получить ключ в Telegram-боте',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.bgCard.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.border.withValues(alpha: .5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 18, color: AtlasTheme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Если у вас пока нет подписки, вы можете получить её в боте или на сайте.',
                  style: TextStyle(fontSize: 12, color: c.textSecondary, height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomControls(ThemeColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        color: c.bgBase,
        border: Border(top: BorderSide(color: c.border.withValues(alpha: .5))),
      ),
      child: Row(
        children: [
          if (_step > 0)
            Semantics(
              button: true,
              label: 'Назад',
              child: TextButton(
                onPressed: () => setState(() => _step -= 1),
                child: Text(
                  'Назад',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.textSecondary,
                  ),
                ),
              ),
            )
          else
            Semantics(
              button: true,
              label: 'Пропустить',
              child: TextButton(
                onPressed: _finish,
                child: Text(
                  'Пропустить',
                  style: TextStyle(
                    fontSize: 14,
                    color: c.textMuted,
                  ),
                ),
              ),
            ),
          const Spacer(),
          ElevatedButton(
            onPressed: _importing
                ? null
                : () {
                    if (_step < 2) {
                      setState(() => _step += 1);
                    } else {
                      _finish();
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: AtlasTheme.accent,
              foregroundColor: AtlasTheme.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: _importing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _step < 2 ? 'Далее' : 'Завершить',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _step < 2 ? Icons.arrow_forward_rounded : Icons.check_rounded,
                        size: 17,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
