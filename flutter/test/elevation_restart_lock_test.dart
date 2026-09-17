import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression: the settings-screen UAC restart path must release the GUI
/// instance lock before spawning the elevated relaunch, and must request the
/// connect-on-start resume. The dashboard path (elevation_prompt.dart) already
/// followed this contract; settings_screen.dart silently exited the fresh
/// instance because main() bails out when the lock is still held.
void main() {
  test('settings UAC restart releases gui.lock and passes connect-on-start',
      () async {
    final source = File(
      'lib/features/settings/settings_screen.dart',
    ).readAsStringSync();

    // The elevated relaunch inside _checkTunElevation must be preceded by a
    // lock release and must carry the resume flag.
    final restartBlock = RegExp(
      r'release\(\);[\s\S]{0,200}relaunchElevated\([\s\S]{0,80}connectOnStart: true',
    ).hasMatch(source);
    expect(restartBlock, isTrue,
        reason: 'settings_screen must release gui.lock and pass '
            'connectOnStart: true before relaunchElevated');
  });

  test('main() consumes the resume flag before the lock gate', () async {
    final main = File('lib/main.dart').readAsStringSync();
    final consumeBeforeLock = main.indexOf('consumeLaunchArguments') <
        main.indexOf('DesktopInstanceLock.instance');
    expect(consumeBeforeLock, isTrue);
  });
}
