import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosaic_vpn/core/providers/logs_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/features/logs/logs_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/diagnostic_redaction.dart';

class _SeededLogs extends LogsNotifier {
  _SeededLogs(super.ref) {
    state = LogsState(entries: [LogEntry(timestamp: DateTime(2026), level: 'ERROR', message: 'dial https://private.example/export-secret timeout')]);
  }
}

void main() {
  testWidgets('Copy exports sanitized logs, not raw connection data', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        logsProvider.overrideWith((ref) => _SeededLogs(ref)),
      ],
      child: const MaterialApp(home: Scaffold(body: LogsScreen())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, contains('timeout'));
    expect(copied, isNot(contains('export-secret')));
    expect(copied, isNot(contains('private.example')));
    await tester.pumpWidget(const SizedBox());
  });
  test('redacts structured secrets addresses and traffic destinations', () {
    const input = '''TLS timeout 12ms HTTP 503
Authorization: Bearer opaque_token+/==
{"password": "two word secret", "private_key":"key-material"}
token=plain-secret uuid=ab012345-6789-4abc-8def-0123456789ab
connect 192.0.2.1:443 [2001:db8::1]:443 example.org:443
email person@example.org''';
    final result = redactDiagnosticText(input);
    for (final secret in ['opaque_token', 'two word secret', 'key-material',
      'plain-secret', 'ab012345', '192.0.2.1', '2001:db8', 'example.org', 'person@']) {
      expect(result, isNot(contains(secret)), reason: secret);
    }
    expect(result, contains('TLS timeout 12ms HTTP 503'));
  });
  test('export removes connection URI credentials and keeps failure reason', () {
    final result = redactDiagnosticText(
      'dial vless://private-user@node.example:443?security=reality#private-name timeout',
    );
    expect(result, contains('timeout'));
    for (final secret in ['private-user', 'node.example', 'private-name']) {
      expect(result, isNot(contains(secret)));
    }
  });
}
