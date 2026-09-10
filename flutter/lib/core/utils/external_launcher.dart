import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class ExternalLauncher {
  ExternalLauncher._();

  /// Safely open a Telegram bot or link, trying deep link (tg://) first,
  /// then fallback to browser URL (https://t.me/...), handling platform quirks.
  static Future<bool> openTelegram(String username, {String? startParam}) async {
    final cleanUsername = username.replaceAll('@', '').trim();

    final nativeUri = Uri(
      scheme: 'tg',
      host: 'resolve',
      queryParameters: {
        'domain': cleanUsername,
        if (startParam != null && startParam.isNotEmpty) 'start': startParam,
      },
    );
    final webUri = Uri.https(
      't.me',
      '/$cleanUsername',
      (startParam != null && startParam.isNotEmpty) ? {'start': startParam} : null,
    );

    try {
      // 1. Try native telegram scheme first
      if (await canLaunchUrl(nativeUri)) {
        final ok = await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
        if (ok) return true;
      }
    } catch (e) {
      debugPrint('[ExternalLauncher] Failed to launch native tg URI: $e');
    }

    try {
      // 2. Fallback to https://t.me web URL with external application mode
      if (await canLaunchUrl(webUri)) {
        final ok = await launchUrl(webUri, mode: LaunchMode.externalApplication);
        if (ok) return true;
      }
      // 3. Fallback to platform default mode if externalApplication fails
      return await launchUrl(webUri, mode: LaunchMode.platformDefault);
    } catch (e) {
      debugPrint('[ExternalLauncher] Failed to launch web tg URI: $e');
      return false;
    }
  }

  /// Open any general web URL reliably (supports String or Uri)
  static Future<bool> openUrl(dynamic urlOrUri) async {
    final Uri? uri = urlOrUri is Uri
        ? urlOrUri
        : Uri.tryParse(urlOrUri.toString().trim());
    if (uri == null) return false;

    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (e) {
      debugPrint('[ExternalLauncher] Failed to open URL $urlOrUri: $e');
      return false;
    }
  }
}
