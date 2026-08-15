import 'dart:async';
import 'dart:io';

import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_platform.dart';

typedef TrayAction = FutureOr<void> Function();

/// Manages the desktop tray icon, status-aware context menu and window state.
///
/// Closing the window can minimize the client to the tray while retaining an
/// active VPN. Explicit **Quit MosaicVPN** is deliberately different: AppShell
/// first asks the local daemon to shut down, which disconnects and reaps its
/// sing-box child before the Flutter process exits.
class TrayService {
  static final TrayService instance = TrayService._();

  TrayService._();

  final SystemTray _tray = SystemTray();
  bool _initialized = false;
  bool _minimizeToTray = false;
  bool _connected = false;
  String _routeLabel = '';
  bool _hidden = false;

  TrayAction? _onConnect;
  TrayAction? _onDisconnect;
  TrayAction? _onOpenRoutes;
  TrayAction? _onQuit;

  bool get isInitialized => _initialized;
  bool get isWindowHidden => _hidden;

  /// Updates retained callbacks only when a non-null action is supplied.
  /// Settings can therefore change close-to-tray behavior without severing
  /// application-level connect/disconnect/quit actions.
  void configure({
    required bool minimizeToTray,
    TrayAction? onConnect,
    TrayAction? onDisconnect,
    TrayAction? onOpenRoutes,
    TrayAction? onQuit,
  }) {
    _minimizeToTray = minimizeToTray;
    if (onConnect != null) _onConnect = onConnect;
    if (onDisconnect != null) _onDisconnect = onDisconnect;
    if (onOpenRoutes != null) _onOpenRoutes = onOpenRoutes;
    if (onQuit != null) _onQuit = onQuit;
    if (_initialized) _buildMenu();
  }

  /// Reflects the current connection state in the next context menu rebuild.
  void setConnectionState(bool connected, {String routeLabel = ''}) {
    if (_connected == connected && _routeLabel == routeLabel) return;
    _connected = connected;
    _routeLabel = routeLabel;
    if (_initialized) _buildMenu();
  }

  Future<void> init() async {
    if (_initialized || !AppPlatform.isDesktop) return;

    final iconPath = Platform.isWindows
        ? 'assets/icons/app_icon.ico'
        : 'assets/icons/app_icon.png';

    try {
      await _tray.initSystemTray(title: 'MosaicVPN', iconPath: iconPath);
    } catch (_) {
      return;
    }

    _initialized = true;
    _buildMenu();
    _tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        unawaited(showWindow());
      } else if (eventName == kSystemTrayEventRightClick) {
        unawaited(_tray.popUpContextMenu());
      }
    });
  }

  void _buildMenu() {
    final menu = Menu();
    final connectionLabel = _connected
        ? 'Подключено${_routeLabel.isEmpty ? '' : ' · $_routeLabel'}'
        : 'Не подключено';

    menu.buildFrom([
      MenuItemLabel(label: 'MosaicVPN', enabled: false),
      MenuItemLabel(label: connectionLabel, enabled: false),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Открыть приложение',
        onClicked: (_) => showWindow(),
      ),
      MenuItemLabel(
        label: 'Подключить',
        enabled: !_connected,
        onClicked: (_) async {
          await _onConnect?.call();
          await showWindow();
        },
      ),
      MenuItemLabel(
        label: 'Отключить',
        enabled: _connected,
        onClicked: (_) async => _onDisconnect?.call(),
      ),
      MenuItemLabel(
        label: 'Выбрать маршрут',
        onClicked: (_) async {
          await _onOpenRoutes?.call();
          await showWindow();
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Свернуть в трей',
        enabled: !_hidden,
        onClicked: (_) => hideToTray(),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Выйти полностью',
        onClicked: (_) async {
          if (_onQuit != null) {
            await _onQuit!.call();
            return;
          }
          await closeWindowWithoutIntercept();
        },
      ),
    ]);
    _tray.setContextMenu(menu);
  }

  Future<void> hideToTray() async {
    if (!_initialized) return;
    _hidden = true;
    await windowManager.hide();
  }

  Future<void> showWindow() async {
    if (!_initialized) return;
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    _hidden = false;
  }

  /// Allows a final exit after the daemon has stopped cleanly.
  Future<void> closeWindowWithoutIntercept() async {
    if (AppPlatform.isDesktop) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  bool get shouldInterceptClose => _minimizeToTray && _initialized;

  Future<void> dispose() async {
    if (_initialized) {
      await _tray.destroy();
      _initialized = false;
    }
  }
}
