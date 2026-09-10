import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/status.dart';

/// Pins the client half of the runtime truth-check.
///
/// The daemon now holds a session in `verifying` until real traffic has passed
/// through the tunnel. The UI must treat that as "still establishing", never as
/// connected — a green shield over an unverified tunnel is the exact failure
/// this feature exists to prevent.
void main() {
  VpnStatus statusFor(String state) => VpnStatus.fromJson({
        'state': state,
        'tunnel_mode': 'tun',
        'kill_switch': true,
        'bytes_in': 0,
        'bytes_out': 0,
      });

  group('verifying state', () {
    test('is not reported as connected', () {
      final s = statusFor('verifying');
      expect(s.isConnected, isFalse,
          reason: 'an unverified tunnel must never look connected');
      expect(s.isVerifying, isTrue);
    });

    test('counts as connecting so the UI stays in its busy state', () {
      // Every existing call site guards on isConnecting; if verifying were
      // excluded the shell would flash a disconnected look mid-connect.
      expect(statusFor('verifying').isConnecting, isTrue);
    });

    test('is neither disconnected nor an error', () {
      final s = statusFor('verifying');
      expect(s.isDisconnected, isFalse);
      expect(s.hasError, isFalse);
    });
  });

  group('existing states keep their meaning', () {
    test('connected', () {
      final s = statusFor('connected');
      expect(s.isConnected, isTrue);
      expect(s.isVerifying, isFalse);
      expect(s.isConnecting, isFalse);
    });

    test('connecting', () {
      final s = statusFor('connecting');
      expect(s.isConnecting, isTrue);
      expect(s.isVerifying, isFalse);
      expect(s.isConnected, isFalse);
    });

    test('disconnected', () {
      final s = statusFor('disconnected');
      expect(s.isDisconnected, isTrue);
      expect(s.isConnecting, isFalse);
      expect(s.isVerifying, isFalse);
    });

    test('error', () {
      final s = statusFor('error');
      expect(s.hasError, isTrue);
      expect(s.isConnected, isFalse);
      expect(s.isVerifying, isFalse);
    });
  });

  test('an unknown state never masquerades as connected', () {
    // Forward compatibility: a newer daemon may add states this build does not
    // know. Defaulting to "connected" would be the dangerous direction.
    final s = statusFor('some_future_state');
    expect(s.isConnected, isFalse);
    expect(s.isVerifying, isFalse);
  });
}
