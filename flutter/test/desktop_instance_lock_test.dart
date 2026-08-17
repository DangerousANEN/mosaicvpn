import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/desktop_instance_lock.dart';

void main() {
  test('only one GUI instance can hold the lock', () async {
    final root = await Directory.systemTemp.createTemp('mosaic-gui-lock-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}${Platform.pathSeparator}gui.lock';

    final first = DesktopInstanceLock.instance;
    final acquired = await first.acquire(path);
    expect(acquired, isTrue);
    expect(first.isHeld, isTrue);

    // The singleton remains held while the window is hidden in the tray.
    expect(await first.acquire(path), isTrue);

    await first.release();
    expect(await first.acquire(path), isTrue);
    expect(first.isHeld, isTrue);
    await first.release();
    expect(first.isHeld, isFalse);
  });
}
