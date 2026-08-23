import 'dart:io';

import 'package:flutter/material.dart';

import '../api/daemon_api_exception.dart';
import '../theme/atlas_theme.dart';
import 'desktop_instance_lock.dart';
import 'elevation_service.dart';

/// Throne-style UAC recovery for TUN mode on Windows.
///
/// When the daemon answers `elevation_required`, the user is shown the
/// familiar "restart as administrator?" dialog. Accepting relaunches the
/// same executable elevated and resumes the interrupted connection; the
/// old instance exits only after UAC confirmed the launch.
Future<bool> handleElevationRequired(BuildContext context) async {
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
        'Перезапустить MosaicVPN с повышением прав? После перезапуска '
        'подключение продолжится автоматически.',
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

  // Release the GUI instance lock BEFORE the elevated relaunch: the fresh
  // process starts while this one is still tearing down, and a held lock
  // would make it exit silently (Throne avoids this by quitting fast).
  try {
    await DesktopInstanceLock.instance.release();
  } catch (_) {
    // The OS drops the lock during teardown anyway.
  }

  final launched =
      await ElevationService.instance.relaunchElevated(connectOnStart: true);
  if (launched) {
    // Give the UAC-elevated process a moment to take over, then yield.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
  return false;
}

/// True when the error is the daemon's machine-readable elevation demand.
bool isElevationRequiredError(Object error) =>
    error is DaemonApiException && error.code == 'elevation_required';
