import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/platform/app_platform.dart';
import 'core/services/desktop_instance_lock.dart';
import 'core/services/elevation_service.dart';
import 'core/services/tray_service.dart';

/// Set once main() has run: the elevated-restart flow needs to know whether
/// this instance should resume the interrupted TUN connection. AppShell reads
/// it after the first frame, when providers are ready.
final connectOnStartProvider = Provider<bool>((ref) {
  return ElevationService.instance.shouldConnectOnStart;
});

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Throne-style resume flag from an elevated relaunch must be consumed
  // before any async work can lose it.
  ElevationService.instance.consumeLaunchArguments(args);

  if (AppPlatform.isDesktop) {
    final acquired = await DesktopInstanceLock.instance
        .acquire(DesktopInstanceLock.defaultPath());
    if (!acquired) {
      // The first GUI instance remains responsible for the tray and daemon.
      // Do not open a second window or attach a second UI process.
      return;
    }

    // Window manager setup for desktop platforms
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1100, 720),
        minimumSize: Size(900, 600),
        center: true,
        title: 'MosaicVPN',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );

    // System tray actions are registered by AppShell once Riverpod is ready.
    await TrayService.instance.init();

    // Intercept close: hide to tray instead of quitting
    windowManager.setPreventClose(true);
  }

  runApp(const ProviderScope(child: MosaicApp()));
}
