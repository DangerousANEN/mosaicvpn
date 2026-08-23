import 'dart:io';

/// Windows elevation handling for TUN mode, modelled on Throne's flow:
/// detect the missing administrator token, ask once, relaunch the same
/// executable through UAC (`runas`) and reconnect automatically.
///
/// Everything degrades to a no-op on non-Windows platforms: Linux/macOS
/// privilege is decided by the OS at process start.
class ElevationService {
  ElevationService._();

  static final ElevationService instance = ElevationService._();

  /// Command-line flag handed to the relaunched (elevated) instance so it
  /// resumes the interrupted TUN connection instead of waiting for the user
  /// to press Connect again — Throne's `-flag_restart_tun_on` equivalent.
  static const connectOnStartFlag = '--connect-on-start';

  bool? _adminCache;
  bool _connectOnStart = false;

  /// Must be called once from `main(List<String> args)` before any UI runs.
  void consumeLaunchArguments(List<String> args) {
    _connectOnStart = args.contains(connectOnStartFlag);
  }

  /// True when this instance was relaunched to resume a TUN connection.
  bool get shouldConnectOnStart => _connectOnStart;

  /// True when the current process runs with an administrator token.
  /// The token of a live process never changes, so the answer is cached.
  Future<bool> isElevated() async {
    if (!Platform.isWindows) return true;
    final cached = _adminCache;
    if (cached != null) return cached;
    try {
      final result = await Process.run('powershell', const [
        '-NoProfile',
        '-Command',
        '([Security.Principal.WindowsPrincipal]'
            '[Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('
            '[Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]);
      final elevated = result.stdout.toString().trim().toLowerCase() == 'true';
      // A failed probe must not pin a wrong answer for the whole session.
      if (result.exitCode == 0) _adminCache = elevated;
      return elevated;
    } catch (_) {
      return false;
    }
  }

  /// Relaunches this executable elevated, carrying the connect-on-start
  /// flag when requested. Returns false when the user dismissed the UAC
  /// prompt or the relaunch failed — the caller stays responsible for
  /// exiting only after a confirmed acceptance.
  Future<bool> relaunchElevated({required bool connectOnStart}) async {
    if (!Platform.isWindows) return false;
    final exePath = Platform.resolvedExecutable;
    final argumentList =
        connectOnStart ? ' -ArgumentList "$connectOnStartFlag"' : '';
    try {
      final process = await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Start-Process -FilePath "$exePath"$argumentList -Verb RunAs',
        ],
        // No runInShell: cmd.exe mangles quoting for install paths with
        // spaces and swallows PowerShell's real exit code, so a dismissed
        // UAC prompt could be reported as success.
      );
      // Start-Process exits 0 once UAC accepted the launch request; a
      // dismissed prompt surfaces as a non-zero exit code.
      return await process.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
