/// Centralized UI and animation constants.
///
/// Extract magic numbers from widgets into named constants for
/// readability and consistency across the app.
class UiConstants {
  UiConstants._();

  // ── Layout ──
  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacingMd = 16;
  static const double spacingLg = 24;
  static const double spacingXl = 32;

  static const double radiusSm = 6;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;

  // ── Sidebar ──
  static const double sidebarWidth = 220;
  static const double sidebarCollapsedWidth = 64;
  static const double sidebarItemHeight = 44;
  static const double sidebarIconSize = 22;

  // ── Cards / tiles ──
  static const double cardMinHeight = 56;
  static const double tileHeight = 72;
  static const double listTileLeadingSize = 40;

  // ── Map ──
  static const double arcStrokeWidth = 1.5;
  static const double arcAnimationDurationMs = 1200;
  static const double tooltipOffset = 14;
  static const int mapMaxConnections = 50;

  // ── Animations ──
  static const Duration animFast = Duration(milliseconds: 150);
  static const Duration animMedium = Duration(milliseconds: 300);
  static const Duration animSlow = Duration(milliseconds: 500);
  static const Duration animConnection = Duration(milliseconds: 1200);

  // ── Server list ──
  static const int serverListSearchDebounceMs = 300;
  static const int serverListSortDefault = 0; // by name

  // ── Charts ──
  static const int speedGraphMaxPoints = 60;
  static const Duration speedGraphInterval = Duration(seconds: 1);

  // ── Logs ──
  static const int maxLogLinesBuffer = 5000;
  static const int logBatchSize = 200;

  // ── Window ──
  static const double windowMinWidth = 720;
  static const double windowMinHeight = 480;
  static const double windowDefaultWidth = 1200;
  static const double windowDefaultHeight = 800;
}

/// Centralized error types for daemon communication.
sealed class DaemonError {
  const DaemonError();
}

class DaemonConnectionRefused extends DaemonError {
  const DaemonConnectionRefused();
}

class DaemonAuthFailed extends DaemonError {
  const DaemonAuthFailed();
}

class DaemonNotFound extends DaemonError {
  const DaemonNotFound();
}

class DaemonServerError extends DaemonError {
  final String? detail;
  const DaemonServerError({this.detail});
}

class DaemonTimeout extends DaemonError {
  const DaemonTimeout();
}

class DaemonUnknown extends DaemonError {
  final String? detail;
  const DaemonUnknown({this.detail});
}
