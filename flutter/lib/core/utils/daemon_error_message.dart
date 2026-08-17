import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import '../api/unavailable_daemon_api.dart';
import '../i18n/app_strings.dart';

/// Returns a user-facing daemon error without exposing loopback ports, socket
/// codes or Dio internals. The original error remains available in debug logs.
String daemonErrorMessage(BuildContext context, Object error) {
  final s = AppStrings.of(context);
  if (error is VpnRuntimeUnavailableException ||
      (error is DioException &&
          error.type == DioExceptionType.connectionError)) {
    return s.t('daemon_recovering');
  }

  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String && data['error'].isNotEmpty) {
      return data['error'] as String;
    }
  }

  return s.t('daemon_request_failed');
}
