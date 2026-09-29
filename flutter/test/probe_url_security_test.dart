import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/provider_profile.dart';

/// Regression guard: no VPN probe may target cleartext HTTP.
///
/// Background: the smart-group probe default was 'http://1.1.1.1/generate_204'.
/// Android's network security policy rejects cleartext requests from an app
/// with targetSdk >= 28 and no usesCleartextTraffic flag, and this app ships
/// exactly that posture. The request failed in 7ms with
/// "Cleartext HTTP traffic to 1.1.1.1 not permitted", so every candidate looked
/// dead and healthy tunnels were torn down and rotated away from.
///
/// Measured in an isolated targetSdk=36 harness against the shipping posture:
///   http://1.1.1.1/generate_204  -> IOException in 7ms, every round
///   https://1.1.1.1/cdn-cgi/trace -> HTTP 200 in 44-319ms, every round
///
/// So this is not cosmetic: an http:// probe URL here is a functional bug.
void main() {
  group('probe URLs must not rely on cleartext HTTP', () {
    test('ManifestClientPolicy default probe URL is HTTPS', () {
      const policy = ManifestClientPolicy();
      expect(policy.probeUrl.startsWith('https://'), isTrue,
          reason: 'cleartext probes are blocked by Android and look like dead '
              'nodes; got ${policy.probeUrl}');
    });

    test('a policy parsed without probe_url also falls back to HTTPS', () {
      final policy = ManifestClientPolicy.fromJson(const {'mode': 'latency'});
      expect(policy.probeUrl.startsWith('https://'), isTrue,
          reason: 'the server does not send probe_url at all, so the fallback '
              'is what production actually uses; got ${policy.probeUrl}');
    });

    test('the default target answers without DNS so it survives cold start',
        () {
      // The original reason for an IP literal was avoiding DNS cold-start
      // inside a freshly raised tunnel. An HTTPS URL that also uses an IP
      // literal keeps that property.
      const policy = ManifestClientPolicy();
      final uri = Uri.parse(policy.probeUrl);
      expect(uri.host, matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')),
          reason: 'expected a DNS-free IP literal, got ${uri.host}');
    });
  });
}