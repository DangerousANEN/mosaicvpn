import 'dart:io';

/// Process-level lock for the Flutter desktop window.
///
/// The daemon has its own lock, but that still allows multiple GUI processes to
/// attach to the same daemon. This lock prevents a second MosaicVPN window from
/// starting while the first process is alive. The OS releases it automatically
/// if the process crashes.
class DesktopInstanceLock {
  DesktopInstanceLock._();

  static final DesktopInstanceLock instance = DesktopInstanceLock._();

  RandomAccessFile? _file;
  String? _path;

  bool get isHeld => _file != null;
  String? get path => _path;

  static String defaultPath() {
    final env = Platform.environment;
    final override = env['MOSAIC_DATA_DIR'];
    if (override != null && override.isNotEmpty) {
      return '$override${Platform.pathSeparator}gui.lock';
    }

    final executableDir = File(Platform.resolvedExecutable).parent;
    final portableMarker = File(
      '${executableDir.path}${Platform.pathSeparator}portable.mode',
    );
    if (portableMarker.existsSync()) {
      return '${executableDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}gui.lock';
    }

    final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      final root = (local == null || local.isEmpty)
          ? '$home${Platform.pathSeparator}AppData${Platform.pathSeparator}Local'
          : local;
      return '$root${Platform.pathSeparator}Mosaic${Platform.pathSeparator}gui.lock';
    }
    if (Platform.isMacOS) {
      return '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}Mosaic${Platform.pathSeparator}gui.lock';
    }
    final xdg = env['XDG_DATA_HOME'];
    final root = (xdg == null || xdg.isEmpty)
        ? '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share'
        : xdg;
    return '$root${Platform.pathSeparator}mosaic${Platform.pathSeparator}gui.lock';
  }

  Future<bool> acquire(String path) async {
    if (_file != null) return true;

    final file = File(path);
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await handle.lock(FileLock.exclusive);
      await handle.setPosition(0);
      await handle.truncate(0);
      await handle.writeString('$pid\n');
      _file = handle;
      _path = path;
      return true;
    } catch (_) {
      await handle.close();
      return false;
    }
  }

  Future<void> release() async {
    final handle = _file;
    _file = null;
    _path = null;
    if (handle == null) return;
    try {
      await handle.unlock();
    } catch (_) {
      // The OS will release the lock during process teardown.
    }
    await handle.close();
  }
}
