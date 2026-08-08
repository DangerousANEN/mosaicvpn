import 'package:flutter/widgets.dart';

/// Lightweight i18n: EN + RU string tables.
///
/// Usage: `AppStrings.of(context).t	connect`
/// In the widget tree, wrap with `Localizations.localeOf(context)`
/// and map to [AppStrings.forLocale].
///
/// For now this is a simple lookup; can be upgraded to .arb files later.
class AppStrings {
  AppStrings._(this._strings);
  final Map<String, String> _strings;

  String t(String key) => _strings[key] ?? key;

  static const _en = <String, String>{
    'connect': 'Connect',
    'disconnect': 'Disconnect',
    'reconnect': 'Reconnect',
    'connected': 'Connected',
    'disconnected': 'Disconnected',
    'connecting': 'Connecting…',
    'servers': 'Servers',
    'stats': 'Stats',
    'settings': 'Settings',
    'logs': 'Logs',
    'map': 'Map',
    'profile': 'Profile',
    'search': 'Search',
    'add': 'Add',
    'edit': 'Edit',
    'delete': 'Delete',
    'save': 'Save',
    'cancel': 'Cancel',
    'close': 'Close',
    'quit': 'Quit',
    'show': 'Show',
    'hide': 'Hide',
    'enable': 'Enable',
    'disable': 'Disable',
    'enabled': 'Enabled',
    'disabled': 'Disabled',
    'loading': 'Loading…',
    'error': 'Error',
    'retry': 'Retry',
    'no_servers': 'No servers',
    'import_from_clipboard': 'Import from clipboard',
    'server_name': 'Name',
    'address': 'Address',
    'port': 'Port',
    'protocol': 'Protocol',
    'ping': 'Ping',
    'download': 'Download',
    'upload': 'Upload',
    'duration': 'Duration',
    'data_sent': 'Sent',
    'data_received': 'Received',
    'tunnel_mode': 'Tunnel Mode',
    'proxy_mode': 'Proxy Mode',
    'dns': 'DNS',
    'startup': 'Startup',
    'auto_start': 'Auto-start',
    'minimize_to_tray': 'Minimize to tray',
    'notifications': 'Notifications',
    'warp': 'Cloudflare WARP',
    'mcp': 'MCP',
    'kill_switch': 'Kill Switch',
    'language': 'Language',
    'system_default': 'System default',
    'english': 'English',
    'russian': 'Русский',
    'dark_theme': 'Dark',
    'light_theme': 'Light',
    'system_theme': 'System',
    'theme': 'Theme',
    'about': 'About',
    'version': 'Version',
    'status': 'Status',
    'location': 'Location',
    'ip_address': 'IP Address',
    'uptime': 'Uptime',
  };

  static const _ru = <String, String>{
    'connect': 'Подключить',
    'disconnect': 'Отключить',
    'reconnect': 'Переподключить',
    'connected': 'Подключено',
    'disconnected': 'Отключено',
    'connecting': 'Подключение…',
    'servers': 'Серверы',
    'stats': 'Статистика',
    'settings': 'Настройки',
    'logs': 'Логи',
    'map': 'Карта',
    'profile': 'Профиль',
    'search': 'Поиск',
    'add': 'Добавить',
    'edit': 'Изменить',
    'delete': 'Удалить',
    'save': 'Сохранить',
    'cancel': 'Отмена',
    'close': 'Закрыть',
    'quit': 'Выход',
    'show': 'Показать',
    'hide': 'Скрыть',
    'enable': 'Включить',
    'disable': 'Отключить',
    'enabled': 'Включено',
    'disabled': 'Отключено',
    'loading': 'Загрузка…',
    'error': 'Ошибка',
    'retry': 'Повторить',
    'no_servers': 'Нет серверов',
    'import_from_clipboard': 'Импорт из буфера',
    'server_name': 'Имя',
    'address': 'Адрес',
    'port': 'Порт',
    'protocol': 'Протокол',
    'ping': 'Пинг',
    'download': 'Загрузка',
    'upload': 'Отдача',
    'duration': 'Время',
    'data_sent': 'Отправлено',
    'data_received': 'Получено',
    'tunnel_mode': 'Режим туннеля',
    'proxy_mode': 'Режим прокси',
    'dns': 'DNS',
    'startup': 'Запуск',
    'auto_start': 'Автозапуск',
    'minimize_to_tray': 'Свернуть в трей',
    'notifications': 'Уведомления',
    'warp': 'Cloudflare WARP',
    'mcp': 'MCP',
    'kill_switch': 'Kill Switch',
    'language': 'Язык',
    'system_default': 'Системный',
    'english': 'English',
    'russian': 'Русский',
    'dark_theme': 'Тёмная',
    'light_theme': 'Светлая',
    'system_theme': 'Системная',
    'theme': 'Тема',
    'about': 'О приложении',
    'version': 'Версия',
    'status': 'Статус',
    'location': 'Локация',
    'ip_address': 'IP-адрес',
    'uptime': 'Время работы',
  };

  static AppStrings forLocale(Locale locale) {
    switch (locale.languageCode) {
      case 'ru':
        return AppStrings._(_ru);
      default:
        return AppStrings._(_en);
    }
  }

  static AppStrings of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return forLocale(locale);
  }
}
