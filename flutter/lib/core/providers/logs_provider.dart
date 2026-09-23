import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/android_vpn_service.dart';
import '../platform/app_platform.dart';
import 'app_lifecycle_provider.dart';
import 'vpn_providers.dart';

/// A single log line from the daemon / core.
class LogEntry {
  final DateTime timestamp;
  final String level; // INFO, DEBUG, WARN, ERROR
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// Immutable snapshot of the logs state.
class LogsState {
  final List<LogEntry> entries;
  final bool autoScroll;
  final String? levelFilter;

  const LogsState({
    required this.entries,
    this.autoScroll = true,
    this.levelFilter,
  });

  /// Maximum entries kept in memory.
  static const int maxEntries = 1000;

  LogsState copyWith({
    List<LogEntry>? entries,
    bool? autoScroll,
    String? levelFilter,
    bool clearFilter = false,
  }) {
    return LogsState(
      entries: entries ?? this.entries,
      autoScroll: autoScroll ?? this.autoScroll,
      levelFilter: clearFilter ? null : (levelFilter ?? this.levelFilter),
    );
  }

  /// Filtered entries based on levelFilter.
  /// Returns the same list reference when no filter is active (no copy).
  List<LogEntry> get filtered {
    if (levelFilter == null) return entries;
    return entries.where((e) => e.level == levelFilter).toList();
  }
}

/// Notifier that listens to the daemon event stream and collects log entries.
///
/// Uses a single growable internal list that is trimmed in-place.
/// We only create a *new* list reference (state.entries) when we publish
/// a new state snapshot — we do NOT copy the whole list on every event
/// just to append one item.
class LogsNotifier extends StateNotifier<LogsState> {
  final Ref _ref;
  StreamSubscription? _sub;
  Timer? _androidPollTimer;
  ProviderSubscription? _lifecycleSub;
  int _lastAndroidSeq = 0;

  void _startAndroidLogTimer() {
    _androidPollTimer?.cancel();
    _androidPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollAndroidLogs();
    });
  }

  /// Internal mutable buffer — the single source of truth.
  /// state.entries is an unmodifiable view of this list.
  final List<LogEntry> _buffer = [];

  LogsNotifier(this._ref) : super(const LogsState(entries: [])) {
    _subscribe();
  }

  void _subscribe() {
    if (AppPlatform.isAndroid && AndroidVpnService.instance.isSupported) {
      _pollAndroidLogs();
      // Foreground: poll every 2s. Background: the periodic timer is NOT
      // created at all — a timer that fires only to check "are we still
      // backgrounded?" still wakes the CPU. Instead, a one-shot resume
      // listener restarts the timer (and does an immediate fetch) the moment
      // the app returns. This also fixes the interval being frozen at
      // subscription time regardless of later lifecycle changes.
      final isBg = _ref.read(isAppBackgroundedProvider);
      if (!isBg) {
        _startAndroidLogTimer();
      }
      _lifecycleSub?.close();
      _lifecycleSub = _ref.listen(isAppBackgroundedProvider, (prev, next) {
        if (next) {
          _androidPollTimer?.cancel();
          _androidPollTimer = null;
        } else {
          _startAndroidLogTimer();
          _pollAndroidLogs(); // immediate catch-up fetch on resume
        }
      });
      return;
    }

    final api = _ref.read(daemonApiProvider);
    _sub = api.events().listen(
      (event) {
        final (type, data) = event;
        if (type == 'log') {
          _addEntry(LogEntry(
            timestamp: DateTime.now(),
            level: (data['level'] as String?) ?? 'INFO',
            message: (data['msg'] as String?) ?? '',
          ));
        }
      },
      onError: (e) {
        _addEntry(LogEntry(
          timestamp: DateTime.now(),
          level: 'ERROR',
          message: 'event-stream error: $e',
        ));
      },
    );
  }

  Future<void> _pollAndroidLogs() async {
    try {
      final res = await AndroidVpnService.instance.readNativeLogs(afterSeq: _lastAndroidSeq);
      if (res.lines.isNotEmpty) {
        _lastAndroidSeq = res.lastSeq;
        for (final item in res.lines) {
          final line = item.$2.trim();
          if (line.isEmpty) continue;
          final upper = line.toUpperCase();
          final level = upper.contains('ERROR') || upper.contains('FATAL')
              ? 'ERROR'
              : upper.contains('WARN')
                  ? 'WARN'
                  : upper.contains('DEBUG')
                      ? 'DEBUG'
                      : 'INFO';
          _addEntry(LogEntry(
            timestamp: DateTime.now(),
            level: level,
            message: line,
          ));
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _androidPollTimer?.cancel();
    _lifecycleSub?.close();
    _sub?.cancel();
    super.dispose();
  }

  /// Append a single entry to the internal buffer, trim in-place,
  /// then publish a new state snapshot.
  ///
  /// We use a lightweight generation counter so the state object identity
  /// changes (triggers rebuild) without copying the list contents.
  void _addEntry(LogEntry entry) {
    _buffer.add(entry);
    if (_buffer.length > LogsState.maxEntries) {
      final overflow = _buffer.length - LogsState.maxEntries;
      _buffer.removeRange(0, overflow);
    }
    // Publish: new state object (new identity → rebuild) but entries
    // point to a thin UnmodifiableListView wrapper over the SAME buffer.
    // No O(N) list copy per entry.
    state = LogsState(
      entries: UnmodifiableListView(_buffer),
      autoScroll: state.autoScroll,
      levelFilter: state.levelFilter,
    );
  }

  void toggleAutoScroll() {
    state = state.copyWith(autoScroll: !state.autoScroll);
  }

  void setLevelFilter(String? level) {
    if (level == null) {
      state = state.copyWith(clearFilter: true);
    } else {
      state = state.copyWith(levelFilter: level);
    }
  }

  void clear() {
    _buffer.clear();
    state = LogsState(
      entries: const [],
      autoScroll: state.autoScroll,
      levelFilter: state.levelFilter,
    );
  }
}

/// Provider for the logs controller.
///
/// Auto-disposes when no longer watched (i.e. when the Logs screen is
/// not visible). This closes the SSE event stream which otherwise stays
/// active forever and increases ref churn on header-bus data every second.
final logsProvider =
    StateNotifierProvider.autoDispose<LogsNotifier, LogsState>((ref) {
  return LogsNotifier(ref);
});
