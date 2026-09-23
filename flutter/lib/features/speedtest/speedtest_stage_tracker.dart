import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/utils/formatters.dart';
import 'speedtest_models.dart';

/// Horizontal stage progression tracker showing Ping, Download, Upload, and Complete states.
class SpeedtestStageTracker extends StatelessWidget {
  final SpeedTestProgress progress;

  const SpeedtestStageTracker({
    super.key,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          _buildStageItem(
            context: context,
            stageName: 'Ping',
            icon: Icons.bolt,
            state: _getStageState(SpeedTestStage.ping),
            valueText: progress.latencyMs != null
                ? '${progress.latencyMs} ms'
                : (progress.currentPingMs != null
                    ? '${progress.currentPingMs} ms'
                    : null),
          ),
          _buildConnector(context, isCompleted: _isAfter(SpeedTestStage.ping)),
          _buildStageItem(
            context: context,
            stageName: 'Download',
            icon: Icons.south,
            state: _getStageState(SpeedTestStage.download),
            valueText: progress.downloadBps != null && progress.downloadBps! > 0
                ? formatSpeed(progress.downloadBps!)
                : null,
          ),
          _buildConnector(
              context, isCompleted: _isAfter(SpeedTestStage.download)),
          _buildStageItem(
            context: context,
            stageName: 'Upload',
            icon: Icons.north,
            state: _getStageState(SpeedTestStage.upload),
            valueText: progress.uploadBps != null && progress.uploadBps! > 0
                ? formatSpeed(progress.uploadBps!)
                : null,
          ),
          _buildConnector(context, isCompleted: _isAfter(SpeedTestStage.upload)),
          _buildStageItem(
            context: context,
            stageName: 'Complete',
            icon: Icons.done_all,
            state: _getStageState(SpeedTestStage.completed),
            valueText: progress.isCompleted ? 'Done' : null,
          ),
        ],
      ),
    );
  }

  _StageState _getStageState(SpeedTestStage step) {
    if (progress.isCompleted) return _StageState.completed;
    if (progress.stage == step) {
      return _StageState.active;
    }
    if (_isAfter(step)) {
      return _StageState.completed;
    }
    return _StageState.pending;
  }

  bool _isAfter(SpeedTestStage step) {
    final order = [
      SpeedTestStage.idle,
      SpeedTestStage.ping,
      SpeedTestStage.download,
      SpeedTestStage.upload,
      SpeedTestStage.completed,
    ];
    final currentIndex = order.indexOf(progress.stage);
    final stepIndex = order.indexOf(step);
    if (currentIndex == -1 || stepIndex == -1) return false;
    return currentIndex > stepIndex;
  }

  Widget _buildStageItem({
    required BuildContext context,
    required String stageName,
    required IconData icon,
    required _StageState state,
    String? valueText,
  }) {
    final c = ThemeColors.of(context);
    Color circleColor;
    Widget statusIcon;

    switch (state) {
      case _StageState.completed:
        circleColor = AtlasTheme.success;
        statusIcon = const Icon(Icons.check, size: 14, color: AtlasTheme.textOnInk);
        break;
      case _StageState.active:
        circleColor = AtlasTheme.accent;
        statusIcon = const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AtlasTheme.textOnInk),
          ),
        );
        break;
      case _StageState.pending:
        circleColor = c.border.withValues(alpha: 0.5);
        statusIcon = Icon(icon, size: 14, color: c.textMuted);
        break;
    }

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: circleColor,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: statusIcon,
          ),
          const SizedBox(height: 6),
          Text(
            stageName,
            style: TextStyle(
              fontSize: 11,
              fontWeight: state == _StageState.active
                  ? FontWeight.bold
                  : FontWeight.w500,
              color: state == _StageState.active
                  ? AtlasTheme.accent
                  : (state == _StageState.completed
                      ? c.textPrimary
                      : c.textMuted),
            ),
          ),
          if (valueText != null) ...[
            const SizedBox(height: 2),
            Text(
              valueText,
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: state == _StageState.active
                    ? AtlasTheme.accent
                    : (state == _StageState.completed
                        ? AtlasTheme.success
                        : c.textMuted),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConnector(BuildContext context, {required bool isCompleted}) {
    final c = ThemeColors.of(context);
    return Container(
      width: 24,
      height: 2,
      margin: const EdgeInsets.only(bottom: 16),
      color: isCompleted ? AtlasTheme.success : c.border.withValues(alpha: 0.5),
    );
  }
}

enum _StageState {
  pending,
  active,
  completed,
}
