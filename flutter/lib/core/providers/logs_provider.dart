import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// Internal mutable buffer — the single source of truth.
  /// state.entries is an unmodifiable view of this list.
  final List<LogEntry> _buffer = [];

  LogsNotifier(this._ref) : super(const LogsState(entries: [])) {
    _subscribe();
  }

  void _subscribe() {
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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
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
