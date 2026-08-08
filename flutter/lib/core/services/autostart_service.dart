import 'dart:io';
import 'dart:async';

/// Manages OS-level autostart (launch at login) for desktop platforms.
///
/// Windows: writes a registry key under HKCU\Software\Microsoft\Windows\
/// CurrentVersion\Run.
/// Linux: writes a .desktop file in ~/.config/autostart/.
/// macOS: uses LSSharedFileList (not yet; placeholder for future).
class AutostartService {
  static final AutostartService instance = AutostartService._();
  AutostartService._();

  /// Returns true if autostart is enabled.
  Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) {
        return _registryRead();
      } else if (Platform.isLinux) {
        final file = File(
            '${Platform.environment['HOME']}/.config/autostart/mosaic-vpn.desktop');
        return file.existsSync();
      }
    } catch (_) {}
    return false;
  }

  /// Enable or disable autostart.
  Future<void> setEnabled(bool enabled) async {
    try {
      if (Platform.isWindows) {
        if (enabled) {
          _registryWrite();
        } else {
          _registryDelete();
        }
      } else if (Platform.isLinux) {
        final dirPath = '${Platform.environment['HOME']}/.config/autostart';
        final dir = Directory(dirPath);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        final file = File('$dirPath/mosaic-vpn.desktop');
        if (enabled) {
          file.writeAsStringSync('''
[Desktop Entry]
Type=Application
Name=MosaicBox VPN
Exec=${Platform.executable}
Terminal=false
X-GNOME-Autostart-enabled=true
''');
        } else {
          if (file.existsSync()) file.deleteSync();
        }
      }
    } catch (_) {}
  }

  // ── Windows registry helpers ──

  bool _registryRead() {
    final result = Process.runSync('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'MosaicBox',
    ]);
    return result.exitCode == 0;
  }

  void _registryWrite() {
    // Platform.executable gives the path to the Flutter/Dart runtime;
    // for a compiled app it's the exe path. For dev mode we use the
    // windows/runner Debug exe path as a best-effort guess.
    final exe = Platform.executable;
    String fullExe;
    if (exe.endsWith('.exe') && !exe.contains('flutter')) {
      fullExe = '"$exe"';
    } else {
      // Dev mode: point to the built debug exe
      fullExe =
          r'"C:\Users\ANEN\mosaicvpn\flutter\build\windows\x64\runner\Debug\mosaic_vpn.exe"';
    }
    Process.runSync('reg', [
      'add',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'MosaicBox',
      '/t',
      'REG_SZ',
      '/d',
      fullExe,
      '/f',
    ]);
  }

  void _registryDelete() {
    Process.runSync('reg', [
      'delete',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'MosaicBox',
      '/f',
    ]);
  }
}
