import 'package:shared_preferences/shared_preferences.dart';

/// Persists presentation preferences independently from the VPN runtime.
///
/// Theme and locale must remain available before a daemon has started and on
/// Android, where daemon-backed preferences do not exist. This class stores no
/// credentials, subscription links, or other account secrets.
class UiPreferencesService {
  static const _themeModeKey = 'ui.theme_mode';
  static const _languageKey = 'ui.language';

  Future<String?> readThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_themeModeKey);
  }

  Future<void> writeThemeMode(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeModeKey, value);
  }

  Future<String?> readLanguage() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_languageKey);
  }

  Future<void> writeLanguage(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_languageKey, value);
  }
}
