import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/platform/app_platform.dart';
import 'core/services/tray_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppPlatform.isDesktop) {
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
