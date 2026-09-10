import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/diagnostics/diagnostics_screen.dart';

/// The diagnostics screen exists to replace "the internet does not work" with
/// something the user can act on, so these tests assert that findings and their
/// hints actually reach the screen — not merely that it renders.
class _StubApi extends MockDaemonApi {
  _StubApi(this._report, {this.shouldThrow = false});

  final Map<String, dynamic> _report;
  final bool shouldThrow;

  @override
  Future<Map<String, dynamic>> runDiagnostics() async {
    if (shouldThrow) {
      throw StateError('daemon unreachable: connection refused');
    }
    return _report;
  }
}

Map<String, dynamic> _report({
  required bool healthy,
  required List<Map<String, dynamic>> checks,
  String summary = 'Всё в порядке',
}) =>
    {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'healthy': healthy,
      'summary': summary,
      'checks': checks,
    };

Widget _wrap(MockDaemonApi api) => ProviderScope(
      overrides: [daemonApiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: DiagnosticsScreen()),
    );

void main() {
  testWidgets('renders each check with its detail', (tester) async {
    final api = _StubApi(_report(healthy: true, checks: [
      {
        'id': 'clock',
        'title': 'Системное время',
        'ok': true,
        'severity': 'ok',
        'detail': 'точность 1 с',
        'duration_ms': 120,
      },
      {
        'id': 'dns',
        'title': 'DNS',
        'ok': true,
        'severity': 'ok',
        'detail': 'разрешается (2 адрес(ов))',
        'duration_ms': 15,
      },
    ]));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Системное время'), findsOneWidget);
    expect(find.text('DNS'), findsOneWidget);
    expect(find.text('точность 1 с'), findsOneWidget);
    expect(find.text('Всё в порядке'), findsOneWidget);
  });

  testWidgets('a failing check surfaces its actionable hint', (tester) async {
    final api = _StubApi(_report(
      healthy: false,
      summary: 'Найдено проблем: 1',
      checks: [
        {
          'id': 'traffic',
          'title': 'Трафик через туннель',
          'ok': false,
          'severity': 'fail',
          'detail': 'туннель подключён, но данные не проходят',
          'hint': 'Переподключитесь — приложение выберет другой маршрут.',
          'duration_ms': 6000,
        },
      ],
    ));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Найдено проблем: 1'), findsOneWidget);
    expect(find.text('туннель подключён, но данные не проходят'), findsOneWidget);
    // The hint is the entire point: a problem without a next step is useless.
    expect(find.text('Переподключитесь — приложение выберет другой маршрут.'),
        findsOneWidget);
  });

  testWidgets('a daemon failure shows the real reason, not a generic message',
      (tester) async {
    final api = _StubApi(const {}, shouldThrow: true);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    // Hiding the cause here would reproduce exactly the opacity this screen
    // is meant to remove.
    expect(find.textContaining('connection refused'), findsOneWidget);
  });

  testWidgets('runs automatically on open', (tester) async {
    var calls = 0;
    final api = _CountingApi(() => calls++);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(calls, 1,
        reason: 'the user opened diagnostics because they already have a '
            'problem; making them press another button is friction');
  });
}

class _CountingApi extends MockDaemonApi {
  _CountingApi(this.onCall);
  final void Function() onCall;

  @override
  Future<Map<String, dynamic>> runDiagnostics() async {
    onCall();
    return _report(healthy: true, checks: const []);
  }
}
