import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';

/// One-tap connection diagnostics.
///
/// Exists to replace the support conversation that starts with "the internet
/// does not work". Each check maps to a failure that is otherwise invisible to
/// the user — clock skew breaking TLS, a tunnel that carries no traffic, IPv6
/// escaping the tunnel, an MTU that only breaks large transfers — and every
/// problem is paired with something the user can actually do about it.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _running = false;
  Map<String, dynamic>? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Run on open: the user tapped "diagnostics" because they already have a
    // problem, so making them press another button is pure friction.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final api = ref.read(daemonApiProvider);
      final report = await api.runDiagnostics();
      if (!mounted) return;
      setState(() {
        _report = report;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Surface the real reason: a generic "failed" here would reproduce
        // exactly the opacity this screen is meant to remove.
        _error = e.toString();
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final c = ThemeColors.of(context);
    final checks = (_report?['checks'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(
        title: Text(s.t('diagnostics')),
        backgroundColor: c.bgCard,
        actions: [
          IconButton(
            tooltip: s.t('diagnostics_rerun'),
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _headline(context, s, c),
          const SizedBox(height: 16),
          if (_error != null) _errorCard(c),
          for (final raw in checks)
            _checkTile(c, Map<String, dynamic>.from(raw as Map)),
        ],
      ),
    );
  }

  Widget _headline(BuildContext context, AppStrings s, ThemeColors c) {
    if (_running) {
      return Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(s.t('diagnostics_running'),
              style: TextStyle(color: c.textSecondary)),
        ],
      );
    }
    if (_report == null) return const SizedBox.shrink();

    final healthy = _report!['healthy'] == true;
    final summary = (_report!['summary'] ?? '').toString();
    return Row(
      children: [
        Icon(
          healthy ? Icons.check_circle_outline : Icons.error_outline,
          color: healthy ? c.success : c.error,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            summary,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorCard(ThemeColors c) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.error.withValues(alpha: 0.35)),
        ),
        child: Text(_error!, style: TextStyle(color: c.textPrimary)),
      );

  Widget _checkTile(ThemeColors c, Map<String, dynamic> check) {
    final severity = (check['severity'] ?? 'ok').toString();
    final (color, icon) = switch (severity) {
      'fail' => (c.error, Icons.error_outline),
      'warn' => (c.warning, Icons.warning_amber_outlined),
      _ => (c.success, Icons.check_circle_outline),
    };
    final hint = (check['hint'] ?? '').toString();
    final durationMs = (check['duration_ms'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (check['title'] ?? check['id'] ?? '').toString(),
                        style: TextStyle(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (durationMs > 0)
                      Text('$durationMs ms',
                          style: TextStyle(
                              color: c.textMuted, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 4),
                Text((check['detail'] ?? '').toString(),
                    style: TextStyle(color: c.textSecondary, fontSize: 13)),
                if (hint.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(hint,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
