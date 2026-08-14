import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
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

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _codeController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _linking = false;
  String? _linkError;

  @override
  void dispose() {
    _codeController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitCode() async {
    final raw = _codeController.text.trim();
    if (raw.isEmpty) {
      setState(() => _linkError = 'Enter the code from the bot.');
      return;
    }
    setState(() {
      _linking = true;
      _linkError = null;
    });
    try {
      final api = ref.read(daemonApiProvider);
      await api.redeemLinkCode(raw);
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
      setState(() => _linkError = 'Enter a valid email and a password of at least 8 characters.');
      return;
    }
    setState(() { _linking = true; _linkError = null; });
    try {
      await ref.read(daemonApiProvider).loginWithEmail(email, password);
      if (!mounted) return;
      ref.invalidate(billingProfileProvider);
      ref.invalidate(paymentHistoryProvider);
      _passwordController.clear();
      setState(() => _linking = false);
    } catch (_) {
      if (!mounted) return;
      setState(() { _linking = false; _linkError = 'Email or password is incorrect. Try again or create an account on the website.'; });
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
              final maxW = constraints.maxWidth > 720.0 ? 720.0 : double.infinity;
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
          Text(message,
              style: TextStyle(color: c.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Pairing-code entry form shown while the account is unlinked.
class _LinkForm extends StatelessWidget {
  final TextEditingController controller;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool busy;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback onEmailSubmit;

  const _LinkForm({
    required this.controller,
    required this.emailController,
    required this.passwordController,
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onEmailSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Link your account',
              style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Send /link to the Telegram bot and type the 8-character code it '
            'gives you. The code works once and expires in 10 minutes.',
            style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('pairing-code-input'),
            controller: controller,
            enabled: !busy,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 9, // 8 chars plus an optional dash
            onSubmitted: busy ? null : (_) => onSubmit(),
            inputFormatters: [
              // The daemon's alphabet excludes look-alike characters, so
              // filtering here keeps typos from becoming failed requests.
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
            ],
            style: TextStyle(
                color: c.textPrimary, letterSpacing: 2, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Pairing code',
              hintText: 'AB23CD45',
              counterText: '',
              errorText: error,
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
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Link account'),
            ),
          ),
          const SizedBox(height: 20),
          Divider(color: c.border),
          const SizedBox(height: 12),
          Text('Sign in with email', style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: emailController,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: 'Email', filled: true, fillColor: c.bgChild),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: passwordController,
            enabled: !busy,
            obscureText: true,
            onSubmitted: busy ? null : (_) => onEmailSubmit(),
            decoration: InputDecoration(labelText: 'Password', filled: true, fillColor: c.bgChild),
          ),
          const SizedBox(height: 10),
          SizedBox(height: 44, child: OutlinedButton(
            onPressed: busy ? null : onEmailSubmit,
            child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign in with email'),
          )),
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
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
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
                  profile.username.isEmpty ? 'Linked account' : profile.username,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            value: days <= 0 ? 'expired' : 'in $days ${days == 1 ? "day" : "days"}',
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
                valueColor: AlwaysStoppedAnimation(
                    ratio >= 0.9 ? c.danger : c.accent),
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
          Container(width: 6, height: 6,
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
