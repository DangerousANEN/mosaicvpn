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

  bool get isRunning => _monitor?.isRunning ?? false;

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
}
