import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/platform/app_platform.dart';
import '../../core/services/android_mosaic_account_service.dart';
import '../../core/theme/atlas_theme.dart';
import '../../core/utils/external_launcher.dart';
import 'unified_account_panel.dart';

/// Payment history for the linked account, newest first.
final paymentHistoryProvider =
    FutureProvider.autoDispose<List<PaymentEntry>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getPaymentHistory();
});

/// Account cabinet (T-19): subscription state, traffic, payment history and
/// code-based Telegram linking.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen>
    with WidgetsBindingObserver {
  final _codeController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _linking = false;
  String? _linkError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppPlatform.isAndroid) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _finishWebsiteLogin());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AppPlatform.isAndroid) {
      _finishWebsiteLogin();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Normalizes a code copied from Telegram. Separators and spaces are only
  /// presentation characters; the authority accepts the unambiguous 8-symbol
  /// alphabet used by `/link`.
  String _normalizePairingCode(String value) {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final normalized = StringBuffer();
    for (final rune in value.toUpperCase().runes) {
      final symbol = String.fromCharCode(rune);
      if (alphabet.contains(symbol)) normalized.write(symbol);
    }
    return normalized.toString();
  }

  Future<void> _startWebsiteLogin() async {
    if (!AppPlatform.isAndroid || _linking) return;
    setState(() {
      _linking = true;
      _linkError = null;
    });
    try {
      final uri =
          await AndroidMosaicAccountService.instance.beginWebsiteLogin();
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw StateError('Не удалось открыть сайт.');
      }
      if (mounted) setState(() => _linking = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linking = false;
        _linkError =
            'Не удалось открыть вход через сайт. Проверьте интернет и попробуйте снова.';
      });
    }
  }

  Future<void> _finishWebsiteLogin() async {
    if (!AppPlatform.isAndroid || _linking) return;
    try {
      final session = await AndroidMosaicAccountService.instance
          .completeWebsiteLoginIfPresent();
      if (session == null || !mounted) return;
      ref.invalidate(androidMosaicSessionProvider);
      ref.invalidate(billingProfileProvider);
      ref.invalidate(paymentHistoryProvider);
      setState(() => _linkError = null);
    } on DioException catch (_) {
      if (!mounted) return;
      setState(
          () => _linkError = 'Вход через сайт не завершён. Повторите попытку.');
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _linkError = e.message);
    }
  }

  Future<void> _submitCode() async {
    final code = _normalizePairingCode(_codeController.text);
    if (code.length != 8) {
      setState(() => _linkError = LinkCodeError.invalidFormat.message);
      return;
    }
    // Keep the visible value aligned with the exact token sent to the daemon.
    _codeController.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    setState(() {
      _linking = true;
      _linkError = null;
    });
    try {
      if (AppPlatform.isAndroid) {
        await AndroidMosaicAccountService.instance.redeemTelegramCode(code);
        ref.invalidate(androidMosaicSessionProvider);
      } else {
        final api = ref.read(daemonApiProvider);
        await api.redeemLinkCode(code);
      }
      if (!mounted) return;
      // Refresh both the profile and the history: linking changes what the
      // account endpoints return.
      ref.invalidate(billingProfileProvider);
      ref.invalidate(paymentHistoryProvider);
      _codeController.clear();
      setState(() => _linking = false);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _linking = false;
        _linkError = LinkCodeError.fromStatus(e.response?.statusCode).message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linking = false;
        _linkError = LinkCodeError.unknown.message;
      });
    }
  }

  Future<void> _submitEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!email.contains('@') || password.length < 8) {
      setState(() => _linkError =
          'Enter a valid email and a password of at least 8 characters.');
      return;
    }
    setState(() {
      _linking = true;
      _linkError = null;
    });
    try {
      if (AppPlatform.isAndroid) {
        await AndroidMosaicAccountService.instance
            .loginWithEmail(email, password);
        ref.invalidate(androidMosaicSessionProvider);
      } else {
        await ref.read(daemonApiProvider).loginWithEmail(email, password);
      }
      if (!mounted) return;
      ref.invalidate(billingProfileProvider);
      ref.invalidate(paymentHistoryProvider);
      _passwordController.clear();
      setState(() => _linking = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _linking = false;
        _linkError =
            'Email or password is incorrect. Try again or create an account on the website.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final profile = ref.watch(billingProfileProvider);

    return Scaffold(
      backgroundColor: c.bgBase,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(billingProfileProvider);
            ref.invalidate(unifiedAccountProvider);
            ref.invalidate(paymentHistoryProvider);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Cap the column so the cabinet does not stretch into
              // unreadable full-width lines on a desktop window.
              final maxW =
                  constraints.maxWidth > 720.0 ? 720.0 : double.infinity;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Account',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                      color: c.textPrimary,
                                      fontWeight: FontWeight.bold)),
                          const SizedBox(height: 16),
                          profile.when(
                            loading: () => const _CabinetLoading(),
                            error: (e, _) => _CabinetError(message: '$e'),
                            data: (p) => p.linked
                                ? _LinkedBody(profile: p)
                                : _LinkForm(
                                    controller: _codeController,
                                    emailController: _emailController,
                                    passwordController: _passwordController,
                                    busy: _linking,
                                    error: _linkError,
                                    onSubmit: _submitCode,
                                    onEmailSubmit: _submitEmail,
                                    onWebsiteSignIn: _startWebsiteLogin,
                                    websiteFirst: AppPlatform.isAndroid,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CabinetLoading extends StatelessWidget {
  const _CabinetLoading();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _CabinetError extends StatelessWidget {
  final String message;
  const _CabinetError({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off, color: c.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Cabinet unavailable',
                    style: TextStyle(
                        color: c.textPrimary, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Show the real reason rather than a generic message: "daemon not
          // running" and "Remnawave unreachable" need different fixes.
          Text(message, style: TextStyle(color: c.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Pairing-code entry form shown while the account is unlinked.
class _LinkForm extends StatefulWidget {
  final TextEditingController controller;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool busy;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback onEmailSubmit;
  final VoidCallback onWebsiteSignIn;
  final bool websiteFirst;

  const _LinkForm({
    required this.controller,
    required this.emailController,
    required this.passwordController,
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onEmailSubmit,
    required this.onWebsiteSignIn,
    required this.websiteFirst,
  });

  @override
  State<_LinkForm> createState() => _LinkFormState();
}

class _LinkFormState extends State<_LinkForm> {
  late String _tab = 'tg';

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Вход в аккаунт',
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Выберите способ входа для управления подпиской и привязкой устройств.',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            segments: const [
              ButtonSegment(
                value: 'tg',
                icon: Icon(Icons.send_rounded, size: 15),
                label: Text('Telegram'),
              ),
              ButtonSegment(
                value: 'email',
                icon: Icon(Icons.email_outlined, size: 15),
                label: Text('Почта'),
              ),
              ButtonSegment(
                value: 'web',
                icon: Icon(Icons.language_rounded, size: 15),
                label: Text('Сайт'),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 16),
          if (_tab == 'tg') ...[
            Text(
              'Отправьте команду /link нашему Telegram-боту @mosaicvpnbot и введите полученный 8-значный код.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => ExternalLauncher.openTelegram(
                'mosaicvpnbot',
                startParam: 'link',
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Открыть @mosaicvpnbot в Telegram'),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('pairing-code-input'),
              controller: widget.controller,
              enabled: !widget.busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              maxLength: 10,
              onSubmitted: widget.busy ? null : (_) => widget.onSubmit(),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-\s]')),
              ],
              style: TextStyle(
                color: c.textPrimary,
                letterSpacing: 2,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                labelText: 'Код из Telegram (/link)',
                hintText: 'AB23CD45',
                counterText: '',
                errorText: widget.error,
                filled: true,
                fillColor: c.bgChild,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: c.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: widget.busy ? null : widget.onSubmit,
                child: widget.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Войти по коду'),
              ),
            ),
          ] else if (_tab == 'email') ...[
            Text(
              'Вход с почтой и паролем, указанными на сайте или при регистрации.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: widget.emailController,
              enabled: !widget.busy,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'E-mail',
                hintText: 'name@example.com',
                filled: true,
                fillColor: c.bgChild,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.passwordController,
              enabled: !widget.busy,
              obscureText: true,
              onSubmitted: widget.busy ? null : (_) => widget.onEmailSubmit(),
              decoration: InputDecoration(
                labelText: 'Пароль',
                hintText: 'Минимум 10 символов',
                filled: true,
                fillColor: c.bgChild,
              ),
            ),
            if (widget.error != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.error!,
                style: TextStyle(color: c.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: widget.busy ? null : widget.onEmailSubmit,
                child: widget.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Войти с паролем'),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Забыли пароль?'),
                      content: const Text(
                        'Если вы привязывали аккаунт к Telegram, просто отправьте боту @mosaicvpnbot команду /link — пароль вводить не нужно!\n\nТакже сброс пароля доступен в веб-кабинете на сайте sub.zxc1x1.ru.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Понятно'),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            ExternalLauncher.openTelegram(
                              'mosaicvpnbot',
                              startParam: 'link',
                            );
                          },
                          child: const Text('Открыть бота'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Забыли пароль?'),
              ),
            ),
          ] else ...[
            Text(
              'Безопасный вход через веб-кабинет в браузере. После входа приложение свяжется автоматически.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 46,
              child: FilledButton.icon(
                onPressed: widget.busy ? null : widget.onWebsiteSignIn,
                icon: const Icon(Icons.open_in_browser_rounded),
                label: widget.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Открыть сайт для входа'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Cabinet contents once the account is linked.
class _LinkedBody extends ConsumerWidget {
  final BillingProfile profile;
  const _LinkedBody({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(paymentHistoryProvider);
    final unified = ref.watch(unifiedAccountProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        unified.when(
          data: (account) => account == null
              ? _SubscriptionCard(profile: profile)
              : UnifiedAccountPanel(account: account),
          loading: () => _SubscriptionCard(profile: profile),
          error: (_, __) => _SubscriptionCard(profile: profile),
        ),
        const SizedBox(height: 12),
        _TrafficCard(profile: profile),
        const SizedBox(height: 12),
        history.when(
          loading: () => const _Card(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          ),
          error: (e, _) => _CabinetError(message: 'Payment history: $e'),
          data: (rows) => _HistoryCard(rows: rows),
        ),
      ],
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final BillingProfile profile;
  const _SubscriptionCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final days = profile.daysLeft;
    // Expiry drives the colour: a subscription with 3 days left should not
    // look the same as one with 3 months.
    final Color accent = days <= 0
        ? c.danger
        : days <= 5
            ? c.warning
            : c.success;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  profile.username.isEmpty
                      ? 'Linked account'
                      : profile.username,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  profile.status.isEmpty ? 'unknown' : profile.status,
                  style: TextStyle(
                      color: accent, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _KeyValue(
            label: 'Expires',
            value: days <= 0
                ? 'expired'
                : 'in $days ${days == 1 ? "day" : "days"}',
          ),
          if (profile.telegramId != 0)
            _KeyValue(label: 'Telegram ID', value: '${profile.telegramId}'),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final BillingProfile profile;
  const _TrafficCard({required this.profile});

  static String _fmtBytes(int b) {
    if (b <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final limit = profile.trafficLimitBytes;
    final used = profile.usedTrafficBytes;
    final unlimited = limit <= 0;
    // Clamp: an over-limit account would otherwise push the bar past its
    // track and trip a layout assertion.
    final ratio = unlimited ? 0.0 : (used / limit).clamp(0.0, 1.0);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Traffic',
              style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (unlimited)
            Text('${_fmtBytes(used)} used · unlimited',
                style: TextStyle(color: c.textSecondary, fontSize: 12))
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: c.bgChild,
                valueColor:
                    AlwaysStoppedAnimation(ratio >= 0.9 ? c.danger : c.accent),
              ),
            ),
            const SizedBox(height: 8),
            Text('${_fmtBytes(used)} of ${_fmtBytes(limit)}',
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final List<PaymentEntry> rows;
  const _HistoryCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Payment history',
              style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Text('No payments yet.',
                style: TextStyle(color: c.textSecondary, fontSize: 12))
          else
            for (final p in rows) _PaymentRow(entry: p),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  final PaymentEntry entry;
  const _PaymentRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final Color tint = entry.isPaid
        ? c.success
        : entry.isFailed
            ? c.danger
            : c.warning;
    final d = entry.paidAt ?? entry.createdAt;
    final when = d == null
        ? ''
        : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.description.isNotEmpty
                      ? entry.description
                      : entry.days > 0
                          ? '${entry.days} days'
                          : entry.provider,
                  style: TextStyle(color: c.textPrimary, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                if (when.isNotEmpty)
                  Text('$when · ${entry.provider}',
                      style: TextStyle(color: c.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${entry.amount.toStringAsFixed(entry.amount % 1 == 0 ? 0 : 2)} ${entry.currency}',
            style: TextStyle(
                color: tint, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  final String label;
  final String value;
  const _KeyValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: c.textSecondary, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(color: c.textPrimary, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}
