import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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
    return candidateExecutablePathsFor(
      appExecutable: Platform.resolvedExecutable,
      isWindows: Platform.isWindows,
      environment: Platform.environment,
    );
  }

  /// Builds the deterministic desktop lookup order used by [candidateExecutablePaths].
  ///
  /// `MOSAIC_DAEMON_PATH` is deliberately limited to an absolute local path. It
  /// helps portable/self-hosted deployments while never falling back to a
  /// developer-specific directory baked into a public release.
  @visibleForTesting
  static List<String> candidateExecutablePathsFor({
    required String appExecutable,
    required bool isWindows,
    required Map<String, String> environment,
  }) {
    final paths = <String>[];
    final configured = environment['MOSAIC_DAEMON_PATH'];
    if (configured != null && configured.isNotEmpty && _isAbsolutePath(configured)) {
      paths.add(configured);
    }

    final appDir = File(appExecutable).parent.path;
    if (isWindows) {
      paths.add('$appDir\\mosaicd.exe');
      paths.add('$appDir\\bin\\mosaicd.exe');
      paths.add(r'C:\Program Files\MosaicVPN\mosaicd.exe');
      paths.add(r'C:\Program Files\MosaicVPN\bin\mosaicd.exe');
    } else {
      paths.add('$appDir/mosaicd');
      paths.add('$appDir/bin/mosaicd');
      // DEB packages install the UI and the daemon side-by-side here.
      paths.add('/opt/mosaicvpn/mosaicd');
      paths.add('/usr/local/bin/mosaicd');
      paths.add('/usr/bin/mosaicd');
    }

    return paths.toSet().toList(growable: false);
  }

  /// POSIX and Windows absolute paths are both accepted regardless of the
  /// host OS: a deployment override written for the target platform must not
  /// be dropped just because tests or the launcher run on another one.
  static bool _isAbsolutePath(String value) {
    if (value.startsWith('/')) return true;
    if (value.length >= 3 && value.codeUnitAt(1) == 58 /* : */) {
      final drive = value[0].toLowerCase();
      return drive.codeUnitAt(0) >= 0x61 && drive.codeUnitAt(0) <= 0x7A;
    }
    if (value.startsWith(r'\\')) return true;
    return false;
  }

  /// Returns the portable data directory when this executable is a portable
  /// package, or null for an installed/system client.
  String? portableDataDirectory({
    String? appExecutable,
    Map<String, String>? environment,
  }) {
    final executable = appExecutable ?? Platform.resolvedExecutable;
    final env = environment ?? Platform.environment;
    final override = env['MOSAIC_DATA_DIR'];
    if (override != null && override.isNotEmpty) return override;

    final appDir = File(executable).parent;
    final marker = File('${appDir.path}${Platform.pathSeparator}portable.mode');
    if (marker.existsSync()) {
      return '${appDir.path}${Platform.pathSeparator}data';
    }
    return null;
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
  Future<bool> ensureDaemonRunning(
      Future<bool> Function() checkIsRunning) async {
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
      // 3. Start daemon process in detached mode
      final portableData = portableDataDirectory();
      _spawnedProcess = await Process.start(
        exePath,
        [
          if (portableData != null) ...['--data-dir', portableData]
        ],
        mode: ProcessStartMode.detached,
      );

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
