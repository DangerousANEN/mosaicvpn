import 'package:flutter/foundation.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';

import '../platform/app_platform.dart';

/// Manages the system tray icon, menu, and window-show/hide logic.
///
/// When [minimizeToTray] is true, closing the window hides it to tray
/// instead of exiting. The tray menu offers Show / Connect / Disconnect /
/// Quit options.
class TrayService {
  static final TrayService instance = TrayService._();

  TrayService._();

  final SystemTray _tray = SystemTray();
  bool _initialized = false;
  bool _minimizeToTray = false;
  VoidCallback? _onConnect;
  VoidCallback? _onDisconnect;

  bool get isInitialized => _initialized;

  /// Whether the window is currently hidden to tray.
  bool get isWindowHidden => _hidden;
  bool _hidden = false;

  void configure({
    required bool minimizeToTray,
    VoidCallback? onConnect,
    VoidCallback? onDisconnect,
  }) {
    _minimizeToTray = minimizeToTray;
    _onConnect = onConnect;
    _onDisconnect = onDisconnect;
  }

  Future<void> init() async {
    // system_tray and window_manager are desktop-only plugins; calling them on
    // web or mobile throws MissingPluginException.
    if (_initialized || !AppPlatform.isDesktop) return;

    String iconPath;
    if (Platform.isWindows) {
      iconPath = 'assets/icons/app_icon.ico';
    } else if (Platform.isMacOS) {
      iconPath = 'assets/icons/app_icon.png';
    } else {
      iconPath = 'assets/icons/app_icon.png';
    }

    try {
      await _tray.initSystemTray(
        title: 'MosaicBox',
        iconPath: iconPath,
      );
    } catch (_) {
      return; // Tray not available; run without it.
    }

    _buildMenu();
    _initialized = true;
  }

  void _buildMenu() {
    final menu = Menu();
    menu.buildFrom([
      MenuItemLabel(
        label: 'Show MosaicBox',
        onClicked: (item) => showWindow(),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Quick Connect',
        onClicked: (item) {
          _onConnect?.call();
          showWindow();
        },
      ),
      MenuItemLabel(
        label: 'Disconnect',
        onClicked: (item) {
          _onDisconnect?.call();
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Quit',
        onClicked: (item) async {
          await _tray.destroy();
          await windowManager.setPreventClose(false);
          await windowManager.close();
        },
      ),
    ]);
    _tray.setContextMenu(menu);
  }

  /// Hide the window to tray.
  Future<void> hideToTray() async {
    if (!_initialized) return;
    _hidden = true;
    await windowManager.hide();
  }

  /// Show the window from tray.
  Future<void> showWindow() async {
    if (!_initialized) return;
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    _hidden = false;
  }

  /// Called when the user clicks the tray icon.
  void handleTrayClick() {
    if (_hidden) {
      showWindow();
    } else {
      hideToTray();
    }
  }

  /// Whether close should be intercepted (hiding to tray instead).
  bool get shouldInterceptClose => _minimizeToTray && _initialized;

  void dispose() {
    if (_initialized) {
      _tray.destroy();
      _initialized = false;
    }
  }
}
