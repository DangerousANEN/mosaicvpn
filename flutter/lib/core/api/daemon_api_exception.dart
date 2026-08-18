import 'package:dio/dio.dart';

/// A safe, user-presentable failure returned by the authenticated local daemon.
/// The daemon intentionally omits credentials, raw subscription URLs and private
/// pool details; [correlationId] lets support match a local daemon log entry.
class DaemonApiException implements Exception {
  const DaemonApiException({
    required this.message,
    this.code = 'request_failed',
    this.retryable = true,
    this.correlationId,
    this.statusCode,
  });

  final String message;
  final String code;
  final bool retryable;
  final String? correlationId;
  final int? statusCode;

  factory DaemonApiException.fromDio(DioException error) {
    final raw = error.response?.data;
    final data =
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final message = data['error']?.toString().trim();
    final correlation = data['correlation_id']?.toString().trim();
    return DaemonApiException(
      message: message?.isNotEmpty == true
          ? message!
          : 'Не удалось выполнить запрос к VPN runtime.',
      code: data['code']?.toString().trim().isNotEmpty == true
          ? data['code'].toString().trim()
          : 'request_failed',
      retryable: data['retryable'] is bool ? data['retryable'] as bool : true,
      correlationId: correlation?.isNotEmpty == true ? correlation : null,
      statusCode: error.response?.statusCode,
    );
  }

  @override
  String toString() {
    final suffix = correlationId?.isNotEmpty == true
        ? ' Код диагностики: $correlationId.'
        : '';
    return '$message$suffix';
  }
}
