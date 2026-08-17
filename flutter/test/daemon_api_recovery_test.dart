import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mosaic_vpn/core/api/daemon_api.dart';

Future<HttpServer> _statusServer(
    {required void Function(HttpRequest) onRequest}) {
  return HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
    server.listen((request) async {
      onRequest(request);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'agent_connected': true,
          'state': 'disconnected',
          'tunnel_mode': 'tun',
        }));
      await request.response.close();
    });
    return server;
  });
}

void main() {
  test('retries a connection-refused request through refreshed daemon endpoint',
      () async {
    var oldRequests = 0;
    final oldServer = await _statusServer(onRequest: (_) => oldRequests++);
    final oldBaseUrl = 'http://${oldServer.address.address}:${oldServer.port}';

    String? receivedAuthorization;
    final freshServer = await _statusServer(
      onRequest: (request) {
        receivedAuthorization =
            request.headers.value(HttpHeaders.authorizationHeader);
      },
    );
    final freshBaseUrl =
        'http://${freshServer.address.address}:${freshServer.port}';

    // Simulate a daemon shutdown: its former lockfile endpoint is no longer
    // listening, while a new daemon instance has already chosen another port.
    await oldServer.close(force: true);

    var resolverCalls = 0;
    final api = DaemonApi(
      baseUrl: oldBaseUrl,
      token: 'old-token',
      endpointResolver: () async {
        resolverCalls++;
        return (baseUrl: freshBaseUrl, token: 'fresh-token');
      },
    );

    final status = await api.getStatus();

    expect(status.agentConnected, isTrue);
    expect(resolverCalls, 1);
    expect(oldRequests, 0);
    expect(receivedAuthorization, 'Bearer fresh-token');

    await freshServer.close(force: true);
  });
}
