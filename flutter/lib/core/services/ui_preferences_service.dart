import 'package:shared_preferences/shared_preferences.dart';

/// Persists presentation and selection preferences independently from the VPN runtime.
///
/// Theme, locale, and selected/connected route states remain available before a
/// daemon has started and on Android, where daemon-backed preferences do not exist.
/// This class stores no credentials, subscription links, or other account secrets.
class UiPreferencesService {
  static const _themeModeKey = 'ui.theme_mode';
  static const _languageKey = 'ui.language';
  static const _selectedSubscriptionIdKey = 'ui.selected_subscription_id';
  static const _selectedRouteIdKey = 'ui.selected_route_id';
  static const _lastConnectedSubscriptionIdKey =
      'ui.last_connected_subscription_id';
  static const _lastConnectedRouteIdKey = 'ui.last_connected_route_id';
  static const _autoFailoverKey = 'ui.auto_failover';
  static const _bypassRussianSitesKey = 'ui.bypass_russian_sites';
  static const _dismissedHintsKey = 'ui.dismissed_hints';

  Future<bool> readAutoFailover() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_autoFailoverKey) ?? true;
  }

  Future<void> writeAutoFailover(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_autoFailoverKey, value);
  }

  Future<bool> readBypassRussianSites() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_bypassRussianSitesKey) ?? true;
  }

  Future<void> writeBypassRussianSites(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_bypassRussianSitesKey, value);
  }

  Future<Set<String>> readDismissedHints() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getStringList(_dismissedHintsKey) ?? const []).toSet();
  }

  Future<void> dismissHint(String hintId) async {
    final preferences = await SharedPreferences.getInstance();
    final list = preferences.getStringList(_dismissedHintsKey) ?? [];
    if (!list.contains(hintId)) {
      list.add(hintId);
      await preferences.setStringList(_dismissedHintsKey, list);
    }
  }

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

  Future<String?> readSelectedSubscriptionId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_selectedSubscriptionIdKey);
  }

  Future<void> writeSelectedSubscriptionId(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_selectedSubscriptionIdKey, value);
  }

  Future<String?> readSelectedRouteId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_selectedRouteIdKey);
  }

  Future<void> writeSelectedRouteId(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_selectedRouteIdKey, value);
  }

  Future<String?> readLastConnectedSubscriptionId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_lastConnectedSubscriptionIdKey);
  }

  Future<void> writeLastConnectedSubscriptionId(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastConnectedSubscriptionIdKey, value);
  }

  Future<String?> readLastConnectedRouteId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_lastConnectedRouteIdKey);
  }

  Future<void> writeLastConnectedRouteId(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastConnectedRouteIdKey, value);
  }
}
