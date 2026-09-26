import 'dart:async';

/// Live progress of an in-flight connection attempt, rendered by the
/// dashboard while the user waits. Phases mirror the real connect pipeline:
/// candidates fetched from the control plane → TCP sweep of the pool →
/// config build → TUN raise → background egress verification.
class ConnectPhaseEvent {
  const ConnectPhaseEvent({
    required this.phase,
    required this.detail,
    this.candidatesChecked = 0,
    this.candidatesTotal = 0,
    this.candidatesAlive = 0,
  });

  /// One of: 'fetching', 'sweeping', 'connecting', 'verifying', 'done', 'idle'.
  final String phase;

  /// Human-readable detail (already localized by the emitter).
  final String detail;

  /// Sweep progress: how many pool endpoints were TCP-checked.
  final int candidatesChecked;

  /// Sweep progress: pool size.
  final int candidatesTotal;

  /// Sweep progress: endpoints that answered.
  final int candidatesAlive;

  bool get isSweeping => phase == 'sweeping';
}

/// Process-wide connect progress bus. The Android facade and the smart-group
/// selector publish phases; the dashboard subscribes and renders the live
/// node sweep ("Перебор нод 3/12 · живых 2") instead of an anonymous spinner.
class ConnectProgressBus {
  ConnectProgressBus._();

  static final ConnectProgressBus instance = ConnectProgressBus._();

  final _controller = StreamController<ConnectPhaseEvent>.broadcast();

  Stream<ConnectPhaseEvent> get stream => _controller.stream;

  void publish(ConnectPhaseEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void publishSimple(String phase, String detail) =>
      publish(ConnectPhaseEvent(phase: phase, detail: detail));

  void dispose() {
    _controller.close();
  }
}
