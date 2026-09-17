import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings elevates the daemon and keeps the GUI instance alive', () {
    final source = File('lib/features/settings/settings_screen.dart')
        .readAsStringSync();
    final handler = source.substring(source.indexOf('  void _checkTunElevation('),
        source.indexOf('  void _showAboutDialog('));
    expect(handler, contains('handleElevationRequired(context, ref)'));
    expect(handler, isNot(contains('relaunchElevated')));
    expect(handler, isNot(contains('DesktopInstanceLock')));
    expect(handler, isNot(contains('Process.run')));
    expect(handler, isNot(contains('exit(0)')));
    expect(handler, contains('await onAllow()'));
  });

  test('main() consumes the resume flag before the lock gate', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source.indexOf('consumeLaunchArguments'), greaterThanOrEqualTo(0));
    expect(source.indexOf('consumeLaunchArguments'),
        lessThan(source.indexOf('DesktopInstanceLock.instance')));
  });
}
