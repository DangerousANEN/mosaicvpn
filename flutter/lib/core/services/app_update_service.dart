import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';

class AppUpdateInfo {
  final String version;
  final int build;
  final String url;
  final String changelog;

  const AppUpdateInfo({
    required this.version,
    required this.build,
    required this.url,
    required this.changelog,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      version: json['version']?.toString() ?? '',
      build: (json['build'] as num?)?.toInt() ?? 0,
      url: json['url']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
    );
  }
}

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
  ));

  Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://sub.zxc1x1.ru/api/manifest.json',
      );
      final data = res.data;
      if (data == null) return null;
      final updateData = data['app_update'] ?? data['update'];
      if (updateData is Map) {
        final info = AppUpdateInfo.fromJson(Map<String, dynamic>.from(updateData));
        if (_isNewer(info.version, AppConfig.appVersion)) {
          return info;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isNewer(String remote, String local) {
    if (remote.isEmpty || local.isEmpty) return false;
    final rParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final lParts = local.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (rParts.length < 3) {
      rParts.add(0);
    }
    while (lParts.length < 3) {
      lParts.add(0);
    }
    for (var i = 0; i < 3; i++) {
      if (rParts[i] > lParts[i]) return true;
      if (rParts[i] < lParts[i]) return false;
    }
    return false;
  }

  Future<void> checkAndShowPrompt(BuildContext context) async {
    final info = await checkForUpdate();
    if (info == null || !context.mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool('dismiss_update_${info.version}') ?? false;
    if (dismissed) return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _UpdateDialog(info: info),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _dontShowAgain = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: Color(0xFF6366F1)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Доступна версия v${widget.info.version}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.info.changelog.isNotEmpty) ...[
              Text(
                widget.info.changelog,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 16),
            ] else ...[
              const Text(
                'Вышла новая версия приложения с улучшениями стабильности и новыми функциями.',
                style: TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 16),
            ],
            InkWell(
              onTap: () {
                setState(() {
                  _dontShowAgain = !_dontShowAgain;
                });
              },
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _dontShowAgain,
                        onChanged: (val) {
                          setState(() {
                            _dontShowAgain = val ?? false;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Больше не показывать для этой версии',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            if (_dontShowAgain) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('dismiss_update_${widget.info.version}', true);
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Позже'),
        ),
        FilledButton.icon(
          onPressed: () async {
            if (_dontShowAgain) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('dismiss_update_${widget.info.version}', true);
            }
            final uri = Uri.tryParse(widget.info.url);
            if (uri != null) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Обновить'),
        ),
      ],
    );
  }
}
