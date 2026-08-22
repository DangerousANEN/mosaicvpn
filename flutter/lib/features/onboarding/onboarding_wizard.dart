import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/routing_presets_provider.dart';

/// First-launch setup wizard for non-technical users. Three calm steps:
/// 1) pick a routing style (banks bypass / media only / everything),
/// 2) confirm the subscription is in place (or point at enrollment),
/// 3) done — land on the dashboard.
class OnboardingWizard extends ConsumerStatefulWidget {
  const OnboardingWizard({super.key, required this.onDone});

  /// Called after the wizard finishes (or is skipped) so the shell can reveal
  /// the normal navigation.
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
  String? _selectedPresetId;

  static const _choices = [
    (
      id: 'preset-rf-banks',
      icon: Icons.account_balance,
      title: 'Банки — напрямую, остальное — через VPN',
      subtitle:
          'Госуслуги и банковские приложения не заметят VPN. Подходит большинству.',
    ),
    (
      id: 'preset-rf-media',
      icon: Icons.play_circle_outline,
      title: 'Только соцсети через VPN',
      subtitle:
          'Экономит батарею: через туннель идут Telegram, YouTube и Instagram.',
    ),
    (
      id: 'preset-global',
      icon: Icons.shield_outlined,
      title: 'Всё через VPN',
      subtitle: 'Максимальная приватность для всего трафика.',
    ),
  ];

  Future<void> _finish() async {
    await OnboardingWizard.markDone();
    if (_selectedPresetId != null) {
      try {
        final presets = await ref.read(routingPresetsProvider.future);
        for (final preset in presets) {
          if (preset.id == _selectedPresetId) {
            await applyRoutingPreset(ref, preset);
            break;
          }
        }
      } catch (_) {
        // Preferences may not be ready on the very first run; the dashboard
        // tip will offer the same preset later.
      }
    }
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
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _step == 0
                      ? 'Добро пожаловать в MosaicVPN'
                      : _step == 1
                          ? 'Как вы хотите пользоваться VPN?'
                          : 'Всё готово!',
                  style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _step == 0
                      ? 'Настроим всё за минуту — без сложных терминов.'
                      : _step == 1
                          ? 'Можно изменить в любой момент в разделе «Роутинг».'
                          : 'Нажмите большую кнопку на главном экране, чтобы подключиться.',
                  style: TextStyle(fontSize: 14, color: c.textSecondary),
                ),
                const SizedBox(height: 24),
                Expanded(child: _buildStep(c)),
                Row(
                  children: [
                    TextButton(
                      onPressed: _finish,
                      child: Text('Пропустить',
                          style: TextStyle(color: c.textMuted)),
                    ),
                    const Spacer(),
                    if (_step > 0)
                      TextButton(
                        onPressed: () => setState(() => _step -= 1),
                        child: const Text('Назад'),
                      ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _step == 0
                          ? () => setState(() => _step = 1)
                          : _finish,
                      child: Text(_step == 0 ? 'Далее' : 'Начать'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(ThemeColors c) {
    if (_step == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shield_outlined, size: 72, color: c.accent),
            const SizedBox(height: 16),
            Text(
              'Быстро, приватно, понятно',
              style: TextStyle(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 20,
                color: c.textPrimary,
              ),
            ),
          ],
        ),
      );
    }
    if (_step == 1) {
      return ListView.separated(
        itemCount: _choices.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final choice = _choices[i];
          final selected = _selectedPresetId == choice.id;
          return Card(
            color: selected ? c.accent.withValues(alpha: 0.12) : c.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
              side: BorderSide(
                color: selected ? c.accent : c.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: ListTile(
              onTap: () => setState(() => _selectedPresetId = choice.id),
              leading: Icon(choice.icon, color: c.accent, size: 26),
              title: Text(
                choice.title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              subtitle: Text(
                choice.subtitle,
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ),
          );
        },
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 72, color: c.success),
          const SizedBox(height: 16),
          Text(
            'Готово к подключению',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 20,
              color: c.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
