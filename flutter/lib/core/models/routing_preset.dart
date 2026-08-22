import 'dart:convert';

/// A named bundle of routing settings that can be applied with one tap,
/// exported to a file, or imported from a share link.
class RoutingPreset {
  final String id;
  final String name;
  final String description;
  final bool builtIn;

  /// `global` | `rule` | `direct`
  final String routingMode;

  /// Android package names routed THROUGH the tunnel. Empty in global mode
  /// (everything goes through the tunnel anyway).
  final List<String> proxyPackages;

  /// Android package names excluded from the tunnel (banking apps etc).
  /// This is the Exclave-style split-tunneling switch.
  final List<String> bypassPackages;

  const RoutingPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.builtIn,
    required this.routingMode,
    required this.proxyPackages,
    required this.bypassPackages,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'builtIn': builtIn,
        'routingMode': routingMode,
        'proxyPackages': proxyPackages,
        'bypassPackages': bypassPackages,
      };

  factory RoutingPreset.fromJson(Map<String, dynamic> json) => RoutingPreset(
        id: json['id'] as String? ??
            'preset-${DateTime.now().millisecondsSinceEpoch}',
        name: json['name'] as String? ?? 'Пресет',
        description: json['description'] as String? ?? '',
        builtIn: json['builtIn'] as bool? ?? false,
        routingMode: json['routingMode'] as String? ?? 'rule',
        proxyPackages:
            (json['proxyPackages'] as List?)?.cast<String>() ?? const [],
        bypassPackages:
            (json['bypassPackages'] as List?)?.cast<String>() ?? const [],
      );

  String encode() => jsonEncode(toJson());

  static RoutingPreset decode(String raw) =>
      RoutingPreset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Built-in presets shipped with the app. The RF set targets the most common
/// Russian scenario: banks and government apps must NOT go through the VPN
/// because their anti-fraud systems flag foreign IPs.
const List<RoutingPreset> kBuiltInPresets = [
  RoutingPreset(
    id: 'preset-global',
    name: 'Весь трафик через VPN',
    description: 'Все приложения идут через туннель. Максимум приватности.',
    builtIn: true,
    routingMode: 'global',
    proxyPackages: [],
    bypassPackages: [],
  ),
  RoutingPreset(
    id: 'preset-rf-banks',
    name: '🇷🇺 Банки и Госуслуги в обход',
    description:
        'Банковские и государственные приложения работают напрямую — их антифрод '
            'не видит смену IP, а остальной трафик идёт через VPN.',
    builtIn: true,
    routingMode: 'rule',
    proxyPackages: [],
    bypassPackages: [
      // Banks
      'com.bank24.app', // placeholder replaced below at runtime merge
      'ru.sberbankmobile',
      'com.sberbankid.mobile',
      'ru.vtb24.mobilebanking',
      'com.idamob.tinkoff.ru',
      'ru.raiffeisennews', // R-Go / Raiffeisen
      'by.alfabank.by', // Alfa legacy
      'com.alfabank.plus.mobile', // Alfa
      'ru.gazprombank.android.mobilebank.app',
      'com.mtb.mtsbank',
      'ru.otpbank.mobile',
      'ru.pochtabank',
      'ru.russip.myhome', // Rosselkhozbank
      'com.ss.android.bps.sberbank', // SberBusiness
      // Government services
      'ru.gosuslugi.app',
      'ru.gosuslugi.electronicdiary',
      'gov.gosuslugi.edu',
      'com.rt_ru.protectcall', // Rostelecom key system
      'ru.fssp.gov',
      'nalog.gov.ru',
      'ru.nalog.flk',
      // Messengers with phone-number fraud checks often flagged too
      'com.whatsapp',
      // Yandex ecosystem (phone-linked account security)
      'ru.yandex.searchplugin',
      'ru.yandex.mail',
      'ru.yandex.taxi',
      'ru.yandex.yandexwaller', // common typo-safe alias
      'ru.yandex.wallet',
    ],
  ),
  RoutingPreset(
    id: 'preset-rf-media',
    name: '🇷🇺 Только соцсети через VPN',
    description:
        'Через VPN идут заблокированные соцсети и YouTube, всё остальное — напрямую. '
            'Экономит батарею и трафик.',
    builtIn: true,
    routingMode: 'rule',
    proxyPackages: [
      'org.telegram.messenger',
      'org.telegram.plus',
      'com.google.android.youtube',
      'com.instagram.android',
      'com.facebook.katana',
      'com.twitter.android',
      'com.reddit.frontpage',
      'com.linkedin.android',
      'com.discord',
      'com.spotify.music',
      'com.zhiliaoapp.musically', // TikTok
      'com.snapchat.android',
      'com.vimeo.android.videoapp',
      'com.google.android.apps.youtube.music',
    ],
    bypassPackages: [],
  ),
];

/// Merges user presets on top of the built-in list by id.
List<RoutingPreset> mergePresets(
  List<RoutingPreset> builtIn,
  List<RoutingPreset> custom,
) {
  final map = <String, RoutingPreset>{
    for (final preset in builtIn) preset.id: preset,
  };
  for (final preset in custom) {
    map[preset.id] = preset;
  }
  return map.values.toList();
}
