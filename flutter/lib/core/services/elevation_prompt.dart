import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/daemon_api_exception.dart';
import '../providers/vpn_providers.dart';
import '../theme/atlas_theme.dart';
import 'daemon_launcher.dart';

/// Throne-style UAC recovery for TUN mode on Windows.
///
/// When the daemon answers `elevation_required`, the user is asked to elevate
/// the DAEMON (mosaicd), not the GUI: TUN is created by the daemon process,
/// so a GUI-only UAC restart leaves the old non-elevated daemon in place and
/// TUN fails again with the same error (live-verified 2026-09-17). The GUI
/// keeps its window; after the elevated daemon is verified running the
/// interrupted connection is resumed.
Future<bool> handleElevationRequired(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!Platform.isWindows) return false;

  final c = ThemeColors.of(context);
  final confirm = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
      title: const Text('Требуются права администратора',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
      content: const Text(
        'Режим TUN перехватывает весь системный трафик и работает только '
        'с правами администратора.\n\n'
        'Перезапустить сетевую службу с повышением прав? '
        'Окно MosaicVPN останется открытым. Активное подключение '
        'может временно прерваться.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Перезапустить'),
        ),
      ],
    ),
  );
  if (confirm != true) return false;

  // Elevate the DAEMON (mosaicd), not the GUI. The elevated daemon binds a
  // NEW ephemeral port/token, so the check callback re-resolves the endpoint
  // from the lockfile. On success the caller resumes the connection.
  final api = ref.read(daemonApiProvider);
  final ok = await DaemonLauncher.instance.ensureDaemonElevated(
    () async {
      try {
        final status = await api.getStatus().timeout(
              const Duration(seconds: 2),
            );
        return status.daemonElevated;
      } catch (_) {
        return false;
      }
    },
    shutdown: () => api.shutdownDaemon(),
  );
  return ok;
}

/// True when the error is the daemon's machine-readable elevation demand.
bool isElevationRequiredError(Object error) {
  if (error is DaemonApiException && error.code == 'elevation_required') {
    return true;
  }
  final s = error.toString().toLowerCase();
  return s.contains('elevation_required') ||
      s.contains('права администратора') ||
      s.contains('access is denied') ||
      s.contains('отказано в доступе');
}
