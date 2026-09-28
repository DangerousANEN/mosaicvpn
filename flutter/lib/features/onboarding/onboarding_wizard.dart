import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers/vpn_providers.dart';
import '../../core/providers/routing_presets_provider.dart';
import '../../core/services/android_mosaic_account_service.dart';
import '../account/unified_account_panel.dart' show unifiedAccountProvider;
import '../../core/services/ui_preferences_service.dart';
import '../../core/theme/atlas_theme.dart';

/// First-launch setup in the Atlas Zen design language.
///
/// DESIGN RULE (product-mandated): the funnel from "found the app" to "tunnel
/// up" must be as short as physically possible. A brand-new user therefore
/// gets ONE screen with ONE primary action -- create an account and connect on
/// the free trial -- instead of a multi-step wizard that asks them to make
/// decisions they are not equipped to make yet.
///
/// Everything optional (routing mode, ad-block, an existing subscription link,
/// the Telegram code) is demoted to a quiet secondary row or to Settings,
/// where the user can find it later. Advanced users keep every capability;
/// newcomers never have to look at it.
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
  static const _minPasswordLength = 10;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _subUrlController = TextEditingController();

  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  /// Warnings that must not block the happy path (e.g. the account was created
  /// but the default route could not be applied yet).
  String? _notice;

  bool _showExistingSubscription = false;
  bool _showEmailForm = false;

  @override
  void initState() {
    super.initState();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _subUrlController.dispose();
    super.dispose();
  }

  /// A pasted subscription link is the one piece of data a returning user
  /// arrives with. Offering it up front (already filled in) removes a step for
  /// them without adding anything for a new user.
  Future<void> _prefillFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;
      final looksLikeSubscription = text.startsWith('http://') ||
          text.startsWith('https://') ||
          text.startsWith('vless://') ||
          text.startsWith('vmess://') ||
          text.startsWith('ss://') ||
          RegExp(r'^[A-Za-z0-9_-]{8}$').hasMatch(text);
      if (!looksLikeSubscription || !mounted) return;
      setState(() {
        _subUrlController.text = text;
        _showExistingSubscription = true;
      });
    } catch (_) {}
  }

  /// Routing defaults for a normal user: Russian sites and services stay
  /// direct (banks, government, delivery keep working), automatic failover on,
  /// ad-blocking on. Chosen deliberately as defaults so the user never has to
  /// pick a mode on first launch; Settings still exposes every option.
  Future<void> _applySensibleDefaults() async {
    // Best-effort only: onboarding must never fail because a preference could
    // not be written. Every item is something a first-time user would
    // otherwise have to discover and configure by hand.
    final ui = UiPreferencesService();
    try {
      await ui.writeAdBlock(true);
    } catch (_) {}
    try {
      await ui.writeBypassRussianSites(true);
    } catch (_) {}
    try {
      await ui.writeAutoFailover(true);
    } catch (_) {}
    try {
      // "Banks and government services stay direct" is the preset that makes
      // the tunnel feel invisible to a Russian user: local services keep
      // working exactly as before while everything else is protected.
      final presets = await ref.read(routingPresetsProvider.future);
      final localized = presets.firstWhere(
        (preset) => preset.id == 'preset-rf-banks',
        orElse: () => presets.first,
      );
      await applyRoutingPreset(ref, localized);
    } catch (_) {}
  }

  String _friendlyError(Object error) {
    final raw = error.toString().replaceFirst('Bad state: ', '').trim();
    if (raw.contains('409') || raw.toLowerCase().contains('exists')) {
      return 'Аккаунт с этой почтой уже есть. Нажмите «Войти» ниже.';
    }
    if (raw.contains('400')) {
      return 'Проверьте почту и пароль: пароль от $_minPasswordLength символов.';
    }
    if (raw.contains('502') || raw.contains('provider')) {
      return 'Сервис временно недоступен. Попробуйте ещё раз через минуту.';
    }
    if (raw.toLowerCase().contains('socket') ||
        raw.toLowerCase().contains('timeout') ||
        raw.toLowerCase().contains('connection')) {
      return 'Нет связи с сервисом. Проверьте интернет и повторите.';
    }
    return raw.isEmpty ? 'Не удалось выполнить действие. Попробуйте ещё раз.' : raw;
  }

  /// PRIMARY PATH: create the account, persist the subscription, connect.
  /// One tap from the user's perspective; the trial makes it free to try.
  Future<void> _startFreeAndConnect() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Введите почту — на неё придёт доступ.');
      return;
    }
    if (password.length < _minPasswordLength) {
      setState(() => _error =
          'Пароль от $_minPasswordLength символов. Он защищает ваш аккаунт.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    final account = AndroidMosaicAccountService.instance;
    final api = ref.read(daemonApiProvider);
    try {
      // 1. Create the account in-app (no browser trip).
      final session = await account.registerWithEmail(email, password);
      final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
          ? session.subscriptionUrl!.trim()
          : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';

      // 2. Persist the subscription so it survives restarts.
      await api.addSubscription('Моя подписка', subUrl, autoRefresh: true);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);

      // 3. Sensible routing defaults, silently.
      await _applySensibleDefaults();

      if (!mounted) return;
      setState(() => _busy = false);
      // The shell navigates to the connection screen; connecting itself is a
      // single tap on the dashboard compass, where the route table and the
      // live progress card live. Landing the user there is the shortest
      // honest path (the VPN permission dialog must appear in context).
      await OnboardingWizard.markDone();
      if (mounted) widget.onDone();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyError(error);
        // Failed sign-up because the mailbox is taken -> offer sign-in.
        if (_error!.contains('уже есть')) _showEmailForm = true;
      });
    }
  }

  /// ALTERNATE: sign in to an account that already exists (reinstall, second
  /// device). Same one-tap outcome.
  Future<void> _signInAndConnect() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Введите почту и пароль.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = AndroidMosaicAccountService.instance;
    final api = ref.read(daemonApiProvider);
    try {
      final session = await account.loginWithEmail(email, password);
      final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
          ? session.subscriptionUrl!.trim()
          : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';
      await api.addSubscription('Моя подписка', subUrl, autoRefresh: true);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      await _applySensibleDefaults();
      await OnboardingWizard.markDone();
      if (mounted) widget.onDone();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString().contains('401')
            ? 'Неверная почта или пароль.'
            : _friendlyError(error);
      });
    }
  }

  /// An existing subscription is added silently and the app opens on the
  /// connection screen -- no account needed at all.
  Future<void> _finishWithExistingSubscription() async {
    final url = _subUrlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Вставьте ссылку подписки или код из бота.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ref.read(daemonApiProvider);
    try {
      if (RegExp(r'^[A-Za-z0-9_-]{8}$').hasMatch(url)) {
        final session =
            await AndroidMosaicAccountService.instance.redeemTelegramCode(url);
        final subUrl = session.subscriptionUrl?.trim().isNotEmpty == true
            ? session.subscriptionUrl!.trim()
            : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}';
        await api.addSubscription('Моя подписка', subUrl, autoRefresh: true);
      } else if (url.startsWith('mosaicvpn://')) {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await AndroidMosaicAccountService.instance
              .completeEnrollmentCallback(uri);
        }
      } else if (url.startsWith('http://') || url.startsWith('https://')) {
        await api.addSubscription('Моя подписка', url, autoRefresh: true);
      } else {
        throw StateError('Это не похоже на ссылку подписки или код.');
      }
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      await _applySensibleDefaults();
      await OnboardingWizard.markDone();
      if (mounted) widget.onDone();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyError(error);
      });
    }
  }

  Future<void> _skip() async {
    await _applySensibleDefaults();
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
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildBrand(c),
                      const SizedBox(height: 26),
                      Text(
                        'Приватность\nв один шаг',
                        style: TextStyle(
                          fontFamily: AtlasTheme.serifFamily,
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                          height: 1.18,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Создайте аккаунт — и пользуйтесь бесплатно '
                        '$_trialDays дня. Карта не нужна.',
                        style: TextStyle(
                          fontSize: 14.5,
                          color: c.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _buildBenefitStrip(c),
                      const SizedBox(height: 22),
                      if (!_showExistingSubscription) _buildAccountCard(c),
                      if (_showEmailForm && !_showExistingSubscription)
                        _buildExistingHint(c),
                      if (_showExistingSubscription)
                        _buildExistingSubscriptionCard(c),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _buildMessage(c, _error!, isError: true),
                      ],
                      if (_notice != null) ...[
                        const SizedBox(height: 12),
                        _buildMessage(c, _notice!, isError: false),
                      ],
                      const SizedBox(height: 18),
                      _buildPrimaryAction(c),
                      const SizedBox(height: 10),
                      _buildSecondaryRow(c),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _trialDays = 3;

  Widget _buildBrand(ThemeColors c) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AtlasTheme.accent,
                AtlasTheme.accent.withValues(alpha: .7),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(Icons.shield_rounded, size: 17, color: AtlasTheme.onAccent),
        ),
        const SizedBox(width: 9),
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
    );
  }

  Widget _buildBenefitStrip(ThemeColors c) {
    return Row(
      children: [
        Expanded(
          child: _benefit(
            c,
            icon: Icons.bolt_rounded,
            title: 'Быстро',
            desc: 'Подбор\nмаршрута сам',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _benefit(
            c,
            icon: Icons.account_balance_rounded,
            title: 'Удобно',
            desc: 'Банки и\nдоставка — прямо',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _benefit(
            c,
            icon: Icons.lock_rounded,
            title: 'Приватно',
            desc: 'VLESS/Reality\nшифрование',
          ),
        ),
      ],
    );
  }

  Widget _benefit(ThemeColors c,
      {required IconData icon, required String title, required String desc}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: AtlasTheme.accent),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            desc,
            style: TextStyle(fontSize: 11, color: c.textMuted, height: 1.25),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(ThemeColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Почта и пароль',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: _fieldDecoration(c, 'name@example.com'),
            style: TextStyle(color: c.textPrimary, fontSize: 14),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _startFreeAndConnect(),
            decoration: _fieldDecoration(c, 'Пароль от $_minPasswordLength символов',
                suffix: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                    color: c.textMuted,
                  ),
                  tooltip: _obscurePassword ? 'Показать пароль' : 'Скрыть пароль',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                )),
            style: TextStyle(color: c.textPrimary, fontSize: 14),
          ),
          const SizedBox(height: 9),
          Text(
            'Пароль защищает аккаунт. Почта нужна для входа на другом устройстве.',
            style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.3),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(ThemeColors c, String hint,
      {Widget? suffix}) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.textMuted, fontSize: 13.5),
      filled: true,
      fillColor: c.bgBase,
      border: border(c.border),
      enabledBorder: border(c.border),
      focusedBorder: border(AtlasTheme.accent, 1.5),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      suffixIcon: suffix,
    );
  }

  Widget _buildExistingHint(ThemeColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        'Уже есть аккаунт? Нажмите «Войти» ниже.',
        style: TextStyle(fontSize: 12, color: c.textMuted),
      ),
    );
  }

  Widget _buildExistingSubscriptionCard(ThemeColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ваша подписка',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _subUrlController,
            maxLines: 2,
            minLines: 1,
            decoration: _fieldDecoration(c, 'Ссылка подписки или код из бота',
                suffix: IconButton(
                  icon: Icon(Icons.paste_rounded, size: 18, color: c.textMuted),
                  tooltip: 'Вставить из буфера',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text?.trim() ?? '';
                    if (text.isNotEmpty) {
                      setState(() => _subUrlController.text = text);
                    }
                  },
                )),
            style: TextStyle(color: c.textPrimary, fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(ThemeColors c, String text, {required bool isError}) {
    final color = isError ? AtlasTheme.error : AtlasTheme.success;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: c.textPrimary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryAction(ThemeColors c) {
    final label = _showExistingSubscription ? 'Подключить' : 'Начать бесплатно';
    return Semantics(
      button: true,
      label: label,
      child: ElevatedButton(
        onPressed: _busy
            ? null
            : (_showExistingSubscription
                ? _finishWithExistingSubscription
                : _startFreeAndConnect),
        style: ElevatedButton.styleFrom(
          backgroundColor: AtlasTheme.accent,
          foregroundColor: AtlasTheme.onAccent,
          disabledBackgroundColor: AtlasTheme.accent.withValues(alpha: .5),
          disabledForegroundColor: AtlasTheme.onAccent,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          elevation: 0,
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AtlasTheme.onAccent),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 7),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildSecondaryRow(ThemeColors c) {
    final toggleLabel =
        _showExistingSubscription ? 'Создать аккаунт' : 'У меня есть подписка';
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_showExistingSubscription)
              TextButton(
                onPressed:
                    _busy ? null : () => setState(() => _showEmailForm = true),
                child: Text(
                  'Войти',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: c.textSecondary,
                  ),
                ),
              ),
            if (!_showExistingSubscription)
              Text('·',
                  style: TextStyle(fontSize: 13.5, color: c.textMuted)),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _showExistingSubscription = !_showExistingSubscription;
                        _error = null;
                      }),
              child: Text(
                toggleLabel,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (_showEmailForm && !_showExistingSubscription)
          TextButton(
            onPressed: _busy ? null : _signInAndConnect,
            child: Text(
              'Войти с почтой и паролем',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AtlasTheme.accent,
              ),
            ),
          ),
        TextButton(
          onPressed: _busy ? null : _skip,
          child: Text(
            'Настроить позже',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ),
      ],
    );
  }
}