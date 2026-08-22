import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Service responsible for locating and auto-launching the `mosaicd` Go daemon
/// executable when the Flutter application starts.
class DaemonLauncher {
  static final DaemonLauncher instance = DaemonLauncher._();
  DaemonLauncher._();

  Process? _spawnedProcess;

  /// Returns the spawned daemon process if it was started by this instance.
  Process? get spawnedProcess => _spawnedProcess;

  /// Returns candidate executable paths for the `mosaicd` binary based on platform
  /// and current application working/executable directory.
  List<String> candidateExecutablePaths() {
    if (kIsWeb) return [];
    final paths = <String>[];
    final appExe = Platform.resolvedExecutable;
    final appDir = File(appExe).parent.path;

    if (Platform.isWindows) {
      paths.add('$appDir\\mosaicd.exe');
      paths.add('$appDir\\bin\\mosaicd.exe');
      // Dynamic path: sibling to the Flutter executable
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      paths.add('$exeDir\\mosaicd.exe');
      paths.add('$exeDir\\bin\\mosaicd.exe');
      paths.add(r'C:\Program Files\MosaicVPN\bin\mosaicd.exe');
      paths.add(r'C:\Program Files\MosaicVPN\mosaicd.exe');
    } else {
      paths.add('$appDir/mosaicd');
      paths.add('$appDir/bin/mosaicd');
      paths.add('/usr/local/bin/mosaicd');
      paths.add('/usr/bin/mosaicd');
    }

    return paths;
  }

  /// Locates the `mosaicd` executable if present on disk.
  String? findDaemonExecutable() {
    for (final path in candidateExecutablePaths()) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  /// Attempts to launch `mosaicd` if it is not already running.
  ///
  /// Returns `true` if a daemon process is verified to be running after launch.
  Future<bool> ensureDaemonRunning(Future<bool> Function() checkIsRunning) async {
    // 1. Check if daemon is already running
    if (await checkIsRunning()) {
      return true;
    }

    // 2. Locate daemon binary
    final exePath = findDaemonExecutable();
    if (exePath == null) {
      return false;
    }

    try {
      // 3. Start daemon process in detached mode (desktop only)
      if (!Platform.isAndroid && !Platform.isIOS) {
        _spawnedProcess = await Process.start(
          exePath,
          [],
          mode: ProcessStartMode.detached,
        );
      }

      // 4. Poll checkIsRunning for up to 3 seconds
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 3)) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (await checkIsRunning()) {
          return true;
        }
      }
    } catch (_) {}

    return await checkIsRunning();
  }
}
