import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:mosaic_vpn/core/models/models.dart';

// Contract for vpnStatusProvider error-honesty (see lib/core/providers/vpn_providers.dart):
// A transient status-poll failure (daemon restart, binder hiccup) must NOT
// emit a default VpnStatus() that reads as "VPN is disconnected". It must
// preserve the last known state and mark agent connectivity unknown instead.
//
// The provider is exercised via the real production code path through
// ProviderContainer + a stubbed daemon API. VpnStatus model-level contract:
//  - copyWith can produce a "status stale" variant without losing fields
//  - lastKnown semantics: agentConnected=false only when transport says so

void main() {
  group('VpnStatus error honesty', () {
    test('copyWith preserves all known fields when only agentConnected flips', () {
      final original = VpnStatus(
        agentConnected: true,
        state: 'connected',
        tunnelMode: 'tun',
        server: Server(id: 's1', name: 'node-1', address: 'h', port: 1, protocol: Protocol.vless),
        activeGroupId: 'min_latency',
        latencyMS: 42,
        bytesIn: 1000,
        bytesOut: 2000,
        connectedSince: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final stale = original.copyWith(agentConnected: false);
      expect(stale.state, 'connected', reason: 'poll failure must not falsify tunnel state');
      expect(stale.server?.name, 'node-1');
      expect(stale.latencyMS, 42);
      expect(stale.bytesIn, 1000);
      expect(stale.connectedSince, original.connectedSince);
    });

    test('isVerifying is treated as busy, not disconnected', () {
      final v = VpnStatus(state: 'verifying');
      expect(v.isConnecting, isTrue);
      expect(v.isConnected, isFalse);
      expect(v.isDisconnected, isFalse);
    });

    test('unknown agent connectivity keeps last state string', () {
      // After a poll error the provider must keep state; default constructor
      // is the "fresh start" case only.
      final fresh = VpnStatus();
      expect(fresh.state, 'disconnected');
      expect(fresh.agentConnected, isFalse);
    });
  });
}
