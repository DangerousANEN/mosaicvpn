import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_models.dart';
import 'package:mosaic_vpn/features/speedtest/speedtest_probe.dart';

void main() {
  group('HttpSpeedTestProbe - Proxy Isolation & Strict No DIRECT', () {
    test('proxyAddr configures strictly PROXY without DIRECT fallback', () async {
      final probe = HttpSpeedTestProbe(proxyAddr: '127.0.0.1:9999');

      // Attempting ping through a non-existent proxy should fail immediately
      // with SocketException, proving it does NOT fall back to direct Internet.
      expect(
        () => probe.probePing(
          count: 1,
          pingUrls: ['https://cp.cloudflare.com/generate_204'],
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('proxyAddr is mutable and dynamically updates client proxying', () async {
      final probe = HttpSpeedTestProbe();
      expect(probe.proxyAddr, isNull);

      // Mutate proxyAddr (as done by SpeedTestService prepare on desktop)
      probe.proxyAddr = '127.0.0.1:8888';
      expect(probe.proxyAddr, '127.0.0.1:8888');

      expect(
        () => probe.probePing(
          count: 1,
          pingUrls: ['https://cp.cloudflare.com/generate_204'],
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('HttpSpeedTestProbe - Real Local HttpServer Probes', () {
    late HttpServer server;
    late String serverUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUrl = 'http://${server.address.host}:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('probePing succeeds on HTTP 200/204 and records valid latency', () async {
      server.listen((HttpRequest req) {
        if (req.uri.path == '/ping') {
          req.response.statusCode = HttpStatus.noContent;
          req.response.close();
        } else {
          req.response.statusCode = HttpStatus.notFound;
          req.response.close();
        }
      });

      final probe = HttpSpeedTestProbe();
      final recordedSamples = <int>[];

      final samples = await probe.probePing(
        count: 2,
        pingUrls: ['$serverUrl/ping'],
        onSample: (sampleMs, index, total) {
          recordedSamples.add(sampleMs);
        },
      );

      expect(samples.length, 2);
      expect(recordedSamples.length, 2);
      expect(samples.first, greaterThanOrEqualTo(0));
    });

    test('probePing rejects HTTP errors (4xx/5xx) and throws SocketException', () async {
      server.listen((HttpRequest req) {
        // Return server error - must NOT be accepted as ping success!
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write('Server Error');
        req.response.close();
      });

      final probe = HttpSpeedTestProbe();

      expect(
        () => probe.probePing(
          count: 1,
          pingUrls: ['$serverUrl/error'],
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('probeDownload streams real chunks and emits final isDone progress', () async {
      const payloadSize = 128 * 1024; // 128 KB
      final testData = Uint8List(payloadSize);

      server.listen((HttpRequest req) async {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.binary;
        // Stream in two chunks
        req.response.add(testData.sublist(0, 64 * 1024));
        await req.response.flush();
        await Future.delayed(const Duration(milliseconds: 15));
        req.response.add(testData.sublist(64 * 1024));
        await req.response.close();
      });

      final probe = HttpSpeedTestProbe();
      final chunks = <SpeedChunkProgress>[];

      await for (final chunk in probe.probeDownload(
        sampleBytes: payloadSize,
        maxDuration: const Duration(seconds: 2),
        downloadUrls: ['$serverUrl/download'],
      )) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      final lastChunk = chunks.last;
      expect(lastChunk.isDone, isTrue);
      expect(lastChunk.bytesTransferred, payloadSize);
      expect(lastChunk.currentBps, greaterThan(0));
      expect(lastChunk.progress, 1.0);
    });

    test('probeDownload rejects empty responses (0 bytes) with HttpException', () async {
      server.listen((HttpRequest req) {
        // Respond with 200 OK but completely empty body
        req.response.statusCode = HttpStatus.ok;
        req.response.close();
      });

      final probe = HttpSpeedTestProbe();

      expect(
        probe.probeDownload(
          sampleBytes: 64 * 1024,
          maxDuration: const Duration(seconds: 2),
          downloadUrls: ['$serverUrl/empty'],
        ),
        emitsError(isA<HttpException>()),
      );
    });

    test('probeDownload rejects HTTP errors (500) with HttpException', () async {
      server.listen((HttpRequest req) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.close();
      });

      final probe = HttpSpeedTestProbe();

      expect(
        probe.probeDownload(
          sampleBytes: 64 * 1024,
          maxDuration: const Duration(seconds: 2),
          downloadUrls: ['$serverUrl/fail'],
        ),
        emitsError(isA<HttpException>()),
      );
    });

    test('probeUpload uses chunked transfer encoding and succeeds', () async {
      int receivedBytes = 0;
      bool isChunked = false;
      String? declaredContentLength;

      server.listen((HttpRequest req) async {
        isChunked = req.headers.chunkedTransferEncoding;
        declaredContentLength = req.headers.value(HttpHeaders.contentLengthHeader);

        await for (final chunk in req) {
          receivedBytes += chunk.length;
        }

        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      });

      final probe = HttpSpeedTestProbe();
      const targetUploadBytes = 128 * 1024; // 128 KB
      final chunks = <SpeedChunkProgress>[];

      await for (final chunk in probe.probeUpload(
        sampleBytes: targetUploadBytes,
        maxDuration: const Duration(seconds: 2),
        uploadUrl: '$serverUrl/upload',
      )) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      final lastChunk = chunks.last;
      expect(lastChunk.isDone, isTrue);
      expect(lastChunk.bytesTransferred, targetUploadBytes);
      expect(lastChunk.currentBps, greaterThan(0));

      // Assert chunked encoding protocol invariants
      expect(isChunked, isTrue);
      expect(declaredContentLength, isNull,
          reason: 'Chunked upload must not declare a fixed Content-Length header that could be prematurely aborted');
      expect(receivedBytes, targetUploadBytes);
    });

    test('probeUpload rejects HTTP errors (500) with HttpException', () async {
      server.listen((HttpRequest req) async {
        await req.drain();
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      });

      final probe = HttpSpeedTestProbe();

      expect(
        probe.probeUpload(
          sampleBytes: 64 * 1024,
          maxDuration: const Duration(seconds: 2),
          uploadUrl: '$serverUrl/upload_error',
        ),
        emitsError(isA<HttpException>()),
      );
    });

    test('cancel() cleanly aborts probe without hanging', () async {
      final probe = HttpSpeedTestProbe();

      server.listen((HttpRequest req) async {
        // Slow server that never finishes sending response
        req.response.statusCode = HttpStatus.ok;
        req.response.add(Uint8List(1024));
        await req.response.flush();
        await Future.delayed(const Duration(seconds: 10));
        await req.response.close();
      });

      final downloadFuture = probe.probeDownload(
        sampleBytes: 10 * 1024 * 1024,
        maxDuration: const Duration(seconds: 5),
        downloadUrls: ['$serverUrl/slow'],
      ).toList();

      await Future.delayed(const Duration(milliseconds: 50));
      probe.cancel();

      // Download should finish gracefully upon cancellation without hanging
      final result = await downloadFuture;
      expect(result, isNotNull);
    });
  });
}
