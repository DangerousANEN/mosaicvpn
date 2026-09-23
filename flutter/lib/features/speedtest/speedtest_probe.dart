import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'speedtest_models.dart';

/// Abstract contract for performing low-level speed probes.
abstract class SpeedTestProbe {
  Future<List<int>> probePing({
    int count = 4,
    void Function(int sampleMs, int sampleIndex, int total)? onSample,
    List<String>? pingUrls,
  });

  Stream<SpeedChunkProgress> probeDownload({
    int sampleBytes = 5 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 4),
    List<String> downloadUrls = const [],
  });

  Stream<SpeedChunkProgress> probeUpload({
    int sampleBytes = 2 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 3),
    String uploadUrl = '',
  });

  void cancel();
}

/// Real HTTP-based implementation using Dart HttpClient.
/// Measures real packet round-trips and real chunk streaming throughput.
class HttpSpeedTestProbe implements SpeedTestProbe {
  final HttpClient Function()? clientFactory;

  /// Mutable proxy endpoint (e.g. '127.0.0.1:1081' for desktop HTTP proxy, null for native TUN).
  String? proxyAddr;

  final List<String> defaultPingUrls;
  bool _cancelled = false;
  HttpClient? _activeClient;

  HttpSpeedTestProbe({
    this.clientFactory,
    this.proxyAddr,
    List<String>? pingUrls,
  }) : defaultPingUrls = pingUrls ??
            const [
              'https://cp.cloudflare.com/generate_204',
              'https://speed.cloudflare.com/__down?bytes=0',
              'http://1.1.1.1/generate_204',
            ];

  HttpClient _createClient({Duration timeout = const Duration(seconds: 5)}) {
    final client = clientFactory != null ? clientFactory!() : HttpClient();
    client.connectionTimeout = timeout;
    final proxy = proxyAddr?.trim();
    if (proxy != null && proxy.isNotEmpty) {
      // STRICT NO DIRECT fallback: prevents leaking traffic outside the proxy/VPN tunnel.
      client.findProxy = (uri) => 'PROXY $proxy';
    }
    return client;
  }

  @override
  void cancel() {
    _cancelled = true;
    try {
      _activeClient?.close(force: true);
    } catch (_) {}
    _activeClient = null;
  }

  @override
  Future<List<int>> probePing({
    int count = 4,
    void Function(int sampleMs, int sampleIndex, int total)? onSample,
    List<String>? pingUrls,
  }) async {
    _cancelled = false;
    final samples = <int>[];
    final endpoints = (pingUrls != null && pingUrls.isNotEmpty)
        ? pingUrls
        : defaultPingUrls;

    const probeTimeout = Duration(seconds: 3);

    for (int i = 0; i < count; i++) {
      if (_cancelled) break;
      int? sampleMs;
      for (final endpoint in endpoints) {
        if (_cancelled) break;
        final client = _createClient(timeout: probeTimeout);
        _activeClient = client;
        final sw = Stopwatch()..start();
        try {
          final uri = Uri.parse(endpoint);
          final req = await client.getUrl(uri).timeout(probeTimeout);
          final resp = await req.close().timeout(probeTimeout);
          if (resp.statusCode < 200 || resp.statusCode >= 400) {
            throw HttpException(
              'Ping probe returned status ${resp.statusCode}',
              uri: uri,
            );
          }
          await resp.drain().timeout(probeTimeout);
          sampleMs = sw.elapsedMilliseconds;
          break;
        } catch (_) {
          // Try fallback endpoint
          continue;
        } finally {
          client.close(force: true);
          if (_activeClient == client) {
            _activeClient = null;
          }
        }
      }

      if (_cancelled) break;

      if (sampleMs != null) {
        samples.add(sampleMs);
        onSample?.call(sampleMs, i, count);
      }

      if (i < count - 1 && !_cancelled) {
        await Future.delayed(const Duration(milliseconds: 60));
      }
    }

    if (samples.isEmpty && !_cancelled) {
      throw const SocketException('All latency probe endpoints unreachable');
    }

    return samples;
  }

  @override
  Stream<SpeedChunkProgress> probeDownload({
    int sampleBytes = 5 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 4),
    List<String> downloadUrls = const [],
  }) async* {
    _cancelled = false;
    final url = downloadUrls.isNotEmpty
        ? downloadUrls.first
        : 'https://speed.cloudflare.com/__down?bytes=$sampleBytes';

    final uri = Uri.parse(url);
    final client = _createClient(timeout: maxDuration);
    _activeClient = client;

    try {
      final req = await client.getUrl(uri).timeout(maxDuration);
      final resp = await req.close().timeout(maxDuration);
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        throw HttpException(
          'Download probe returned status ${resp.statusCode}',
          uri: uri,
        );
      }

      int totalBytes = 0;
      int windowBytes = 0;
      final sw = Stopwatch()..start();
      final windowSw = Stopwatch()..start();
      int lastCalculatedBps = 0;

      final chunkTimeout = maxDuration > const Duration(seconds: 3)
          ? const Duration(seconds: 3)
          : maxDuration;

      await for (final chunk in resp.timeout(chunkTimeout)) {
        if (_cancelled) break;
        totalBytes += chunk.length;
        windowBytes += chunk.length;

        if (windowSw.elapsedMilliseconds >= 100) {
          final windowSec = windowSw.elapsedMilliseconds / 1000.0;
          if (windowSec > 0) {
            lastCalculatedBps = ((windowBytes * 8) / windowSec).round();
          }
          windowBytes = 0;
          windowSw.reset();

          final progress = sampleBytes > 0
              ? (totalBytes / sampleBytes).clamp(0.0, 1.0)
              : (sw.elapsedMilliseconds / maxDuration.inMilliseconds)
                  .clamp(0.0, 1.0);

          yield SpeedChunkProgress(
            bytesTransferred: totalBytes,
            targetBytes: sampleBytes,
            currentBps: lastCalculatedBps,
            progress: progress,
          );
        }

        if (sw.elapsedMilliseconds >= maxDuration.inMilliseconds ||
            (sampleBytes > 0 && totalBytes >= sampleBytes)) {
          break;
        }
      }

      if (_cancelled) return;

      if (totalBytes == 0) {
        throw HttpException(
          'Download probe completed with 0 bytes transferred',
          uri: uri,
        );
      }

      final totalSec = sw.elapsedMilliseconds / 1000.0;
      final finalBps = totalSec > 0
          ? ((totalBytes * 8) / totalSec).round()
          : lastCalculatedBps;

      yield SpeedChunkProgress(
        bytesTransferred: totalBytes,
        targetBytes: sampleBytes,
        currentBps: finalBps,
        progress: 1.0,
        isDone: true,
      );
    } catch (_) {
      // Force-closing an active request is expected only on explicit cancel.
      if (!_cancelled) rethrow;
    } finally {
      client.close(force: true);
      if (_activeClient == client) {
        _activeClient = null;
      }
    }
  }

  @override
  Stream<SpeedChunkProgress> probeUpload({
    int sampleBytes = 2 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 3),
    String uploadUrl = '',
  }) async* {
    _cancelled = false;
    final url = uploadUrl.isNotEmpty
        ? uploadUrl
        : 'https://speed.cloudflare.com/__up';

    final uri = Uri.parse(url);
    final client = _createClient(timeout: maxDuration);
    _activeClient = client;

    try {
      final req = await client.postUrl(uri).timeout(maxDuration);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      // Use chunked transfer encoding instead of fixed content-length so time-bounded probes
      // do not terminate early with an unsatisfied declared content-length header.
      req.headers.chunkedTransferEncoding = true;

      final chunkSize = min(64 * 1024, max(1024, sampleBytes));
      final chunkData = Uint8List(chunkSize);
      int totalBytes = 0;
      int windowBytes = 0;
      final sw = Stopwatch()..start();
      final windowSw = Stopwatch()..start();
      int lastCalculatedBps = 0;

      final writeTimeout = maxDuration > const Duration(seconds: 3)
          ? const Duration(seconds: 3)
          : maxDuration;

      while (totalBytes < sampleBytes &&
          sw.elapsedMilliseconds < maxDuration.inMilliseconds &&
          !_cancelled) {
        final toWrite = min(chunkSize, sampleBytes - totalBytes);
        req.add(chunkData.sublist(0, toWrite));
        await req.flush().timeout(writeTimeout);

        totalBytes += toWrite;
        windowBytes += toWrite;

        if (windowSw.elapsedMilliseconds >= 100) {
          final windowSec = windowSw.elapsedMilliseconds / 1000.0;
          if (windowSec > 0) {
            lastCalculatedBps = ((windowBytes * 8) / windowSec).round();
          }
          windowBytes = 0;
          windowSw.reset();

          final progress = sampleBytes > 0
              ? (totalBytes / sampleBytes).clamp(0.0, 1.0)
              : (sw.elapsedMilliseconds / maxDuration.inMilliseconds)
                  .clamp(0.0, 1.0);

          yield SpeedChunkProgress(
            bytesTransferred: totalBytes,
            targetBytes: sampleBytes,
            currentBps: lastCalculatedBps,
            progress: progress,
          );
        }
      }

      if (_cancelled) return;

      if (totalBytes == 0) {
        throw HttpException(
          'Upload probe completed with 0 bytes transferred',
          uri: uri,
        );
      }

      final resp = await req.close().timeout(writeTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        await resp.drain().timeout(const Duration(seconds: 1)).catchError((_) => null);
        throw HttpException(
          'Upload probe returned status ${resp.statusCode}',
          uri: uri,
        );
      }
      await resp.drain().timeout(writeTimeout);

      final totalSec = sw.elapsedMilliseconds / 1000.0;
      final finalBps = totalSec > 0
          ? ((totalBytes * 8) / totalSec).round()
          : lastCalculatedBps;

      yield SpeedChunkProgress(
        bytesTransferred: totalBytes,
        targetBytes: sampleBytes,
        currentBps: finalBps,
        progress: 1.0,
        isDone: true,
      );
    } catch (_) {
      // Force-closing an active request is expected only on explicit cancel.
      if (!_cancelled) rethrow;
    } finally {
      client.close(force: true);
      if (_activeClient == client) {
        _activeClient = null;
      }
    }
  }
}

/// Deterministic mock probe for testing stages, events, and metrics without external network.
class MockSpeedTestProbe implements SpeedTestProbe {
  List<int> mockPingSamples;
  List<SpeedChunkProgress> mockDownloadChunks;
  List<SpeedChunkProgress> mockUploadChunks;
  Duration tickDelay;
  bool shouldFailPing;
  bool shouldFailDownload;
  bool shouldFailUpload;
  bool _cancelled = false;

  MockSpeedTestProbe({
    List<int>? mockPingSamples,
    List<SpeedChunkProgress>? mockDownloadChunks,
    List<SpeedChunkProgress>? mockUploadChunks,
    this.tickDelay = const Duration(milliseconds: 15),
    this.shouldFailPing = false,
    this.shouldFailDownload = false,
    this.shouldFailUpload = false,
  })  : mockPingSamples = mockPingSamples ?? [32, 38, 35, 41],
        mockDownloadChunks = mockDownloadChunks ??
            [
              const SpeedChunkProgress(
                  bytesTransferred: 1048576,
                  targetBytes: 5242880,
                  currentBps: 16000000,
                  progress: 0.2),
              const SpeedChunkProgress(
                  bytesTransferred: 2621440,
                  targetBytes: 5242880,
                  currentBps: 24000000,
                  progress: 0.5),
              const SpeedChunkProgress(
                  bytesTransferred: 4194304,
                  targetBytes: 5242880,
                  currentBps: 32000000,
                  progress: 0.8),
              const SpeedChunkProgress(
                  bytesTransferred: 5242880,
                  targetBytes: 5242880,
                  currentBps: 35000000,
                  progress: 1.0,
                  isDone: true),
            ],
        mockUploadChunks = mockUploadChunks ??
            [
              const SpeedChunkProgress(
                  bytesTransferred: 524288,
                  targetBytes: 2097152,
                  currentBps: 8000000,
                  progress: 0.25),
              const SpeedChunkProgress(
                  bytesTransferred: 1048576,
                  targetBytes: 2097152,
                  currentBps: 12000000,
                  progress: 0.5),
              const SpeedChunkProgress(
                  bytesTransferred: 1572864,
                  targetBytes: 2097152,
                  currentBps: 16000000,
                  progress: 0.75),
              const SpeedChunkProgress(
                  bytesTransferred: 2097152,
                  targetBytes: 2097152,
                  currentBps: 18000000,
                  progress: 1.0,
                  isDone: true),
            ];

  @override
  void cancel() {
    _cancelled = true;
  }

  @override
  Future<List<int>> probePing({
    int count = 4,
    void Function(int sampleMs, int sampleIndex, int total)? onSample,
    List<String>? pingUrls,
  }) async {
    _cancelled = false;
    if (shouldFailPing) {
      throw const SocketException('Simulated latency probe failure');
    }
    final samples = <int>[];
    final total = min(count, mockPingSamples.length);
    for (int i = 0; i < total; i++) {
      if (_cancelled) break;
      if (tickDelay > Duration.zero) {
        await Future.delayed(tickDelay);
      }
      final s = mockPingSamples[i];
      samples.add(s);
      onSample?.call(s, i, total);
    }
    return samples;
  }

  @override
  Stream<SpeedChunkProgress> probeDownload({
    int sampleBytes = 5 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 4),
    List<String> downloadUrls = const [],
  }) async* {
    _cancelled = false;
    if (shouldFailDownload) {
      throw const HttpException('Simulated download probe failure');
    }
    for (final chunk in mockDownloadChunks) {
      if (_cancelled) break;
      if (tickDelay > Duration.zero) {
        await Future.delayed(tickDelay);
      }
      yield chunk;
    }
  }

  @override
  Stream<SpeedChunkProgress> probeUpload({
    int sampleBytes = 2 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 3),
    String uploadUrl = '',
  }) async* {
    _cancelled = false;
    if (shouldFailUpload) {
      throw const HttpException('Simulated upload probe failure');
    }
    for (final chunk in mockUploadChunks) {
      if (_cancelled) break;
      if (tickDelay > Duration.zero) {
        await Future.delayed(tickDelay);
      }
      yield chunk;
    }
  }
}
