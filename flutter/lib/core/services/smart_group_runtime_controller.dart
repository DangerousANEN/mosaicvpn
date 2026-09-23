import '../api/daemon_api_base.dart';
import '../models/models.dart';
import 'smart_group_quality_monitor.dart';
import 'smart_group_selector.dart';

/// Process-wide owner of Smart Group runtime monitoring.
///
/// All connection entry points use this controller so a widget rebuild or tab
/// switch cannot orphan a monitor. Android currently uses its native group
/// runtime and therefore does not start this desktop daemon monitor.
class SmartGroupRuntimeController {
  SmartGroupRuntimeController._();

  static final SmartGroupRuntimeController instance =
      SmartGroupRuntimeController._();

  SmartGroupQualityMonitor? _monitor;
  bool _prewarmInFlight = false;
  DateTime? _lastPrewarmAt;

  bool get isRunning => _monitor?.isRunning ?? false;

  /// Resets the prewarm throttle so tests can exercise the cold-start path.
  /// Public for test-only reset; production code never calls this.
  void debugResetPrewarmThrottle() {
    _lastPrewarmAt = null;
    _prewarmInFlight = false;
  }

  /// Pauses quality probing (app backgrounded). Saves battery on mobile.
  void pause() => _monitor?.pause();

  /// Resumes quality probing (app foregrounded).
  void resume() => _monitor?.resume();

  /// Background probe-cache warmup for the groups the user is NOT connected
  /// to. Probe results go into the selector cache (TTL per policy), so the
  /// first connect on any group is near-instant instead of cold-probing all
  /// shard candidates. Throttled to one full pass per 15 minutes (probe TTL
  /// is 600s; a pass keeps every group's cache warm within budget) and
  /// skipped when a prewarm is already in flight.
  Future<void> prewarmGroups({
    required DaemonApiBase api,
    required SmartGroupSelector selector,
    required List<ManifestGroup> groups,
    bool force = false,
  }) async {
    if (_prewarmInFlight) return;
    final now = DateTime.now();
    if (!force &&
        _lastPrewarmAt != null &&
        now.difference(_lastPrewarmAt!) < const Duration(minutes: 15)) {
      return;
    }
    final eligible = groups
        .where((g) => !g.disabled && g.category != 'raw')
        .toList();
    if (eligible.isEmpty) return;
    _prewarmInFlight = true;
    try {
      for (final group in eligible) {
        try {
          await selector.rank(api, group, measureSpeed: false);
        } catch (_) {
          // Group may be provider-disabled mid-warmup; skip it.
        }
      }
      _lastPrewarmAt = DateTime.now();
    } finally {
      _prewarmInFlight = false;
    }
  }

  void start({
    required DaemonApiBase api,
    required SmartGroupSelector selector,
    required ManifestGroup group,
    required String candidateId,
  }) {
    stop();
    final monitor = SmartGroupQualityMonitor(
      api: api,
      selector: selector,
      config: MonitorConfig.fromPolicy(group.clientPolicy),
    );
    monitor.onSwitchCandidate = api.connectGroupCandidate;
    monitor.start(group: group, activeCandidateId: candidateId);
    _monitor = monitor;
  }

  void stop() {
    _monitor?.dispose();
    _monitor = null;
  }

  void dispose() {
    stop();
  }
}
