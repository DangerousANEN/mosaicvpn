# Аудит кросс-платформенной готовности MosaicVPN Flutter-клиента
**Дата:** 12 августа 2026 г.  
**Аудитор:** AI Static Analysis (READ-ONLY)  
**Flutter SDK:** 3.44.6  
**Состояние:** только чтение — никакие файлы не изменялись

---

## РЕЗЮМЕ ВЫВОДОВ

| Приоритет | Проблема | Статус |
|-----------|----------|--------|
| **P0** | Android не может установить VPN-туннель — нет `VpnService`, нет Go-процесса, нет туннельного интерфейса | ПОДТВЕРЖДЕНО |
| **P0** | `_AppShellState with WindowListener` — класс из desktop-only плагина смешивается в тип мобильной оболочки | ПОДТВЕРЖДЕНО |
| **P0** | `DaemonLauncher.ensureDaemonRunning()` вызывает `Process.start` на Android — немедленное исключение | ПОДТВЕРЖДЕНО |
| **P1** | `_QuickStatusBar` высотой 48 px без `SafeArea` — перекрывается статус-баром Android | ПОДТВЕРЖДЕНО |
| **P1** | `EdgeInsets.all(24)` в 16 экранах — на 360 dp оставляет контенту только 312 dp | ПОДТВЕРЖДЕНО |
| **P1** | `AutostartService.setEnabled()` вызывает `Process.runSync('reg', ...)` и `Process.runSync('reg', ...)` без проверки платформы | ПОДТВЕРЖДЕНО |
| **P1** | `Process.start('explorer', ...)`, `Process.start('rundll32', ...)`, `Process.start('powershell', ...)` без `isDesktop`-гарда | ПОДТВЕРЖДЕНО |
| **P1** | Мобильные пользователи не имеют доступа к 11 экранам (Stations, Profiles, Account, Provider, Routes, Egresses, Activity, Stats, Speed Test, Cores, Logs, Settings через боковую панель) | ПОДТВЕРЖДЕНО |
| **P2** | Разрозненные точки останова: 420, 480, 600, 720, 900 — нет единого источника истины | ПОДТВЕРЖДЕНО |
| **P2** | Нет тестов dashboard/settings на телефонном разрешении | ПОДТВЕРЖДЕНО |

---

## 1. ANDROID: ПОЧЕМУ VPN-ТУННЕЛЬ НЕ РАБОТАЕТ ПРИНЦИПИАЛЬНО

### 1.1 Отсутствие разрешений VpnService

**ПОДТВЕРЖДЕНО** — `flutter/android/app/src/main/AndroidManifest.xml` (все 52 строки прочитаны):

```xml
<!-- строки 3–7 -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

**Отсутствуют:**
- `android.permission.BIND_VPN_SERVICE` — требуется для любого `VpnService`
- `<service android:name=".MosaicVpnService" android:permission="android.permission.BIND_VPN_SERVICE">`
- `VpnService.prepare(context)` — запрос пользовательского разрешения (системный диалог)

Без этого Android **не выдаёт дескриптор TUN-устройства**. VPN-профиль физически не может быть установлен.

### 1.2 Полный путь вызова при нажатии «Connect» на Android

```
ConnectToggle.onTap()                        [dashboard_screen.dart:398–430]
  └─ _connectToServer(targetId)              [dashboard_screen.dart:293]
       └─ api.connect(serverId)              [daemon_api.dart:37]
            └─ _dio.post('/v1/connect')      [daemon_api.dart:37]
                 └─ DIO → http://127.0.0.1:{port}/v1/connect
                          ▲
                          │  МЁРТВЫЙ КОНЕЦ: Go-демон не запущен на Android
```

**Разрешение дескриптора API** (`vpn_providers.dart:134–155`):
```dart
// _tryRealDaemon() ищет daemon.lock
for (final lockPath in _candidateLockfilePaths()) {
  final file = File(lockPath);         // ← File.existsSync() OK на Android
  if (!file.existsSync()) continue;   // lockfile НИКОГДА не существует →
  // ...                              //   возвращает null
}
// Если lockfile не найден:
await DaemonLauncher.instance.ensureDaemonRunning(...)  // ← ПАДЕНИЕ см. 1.3
```

### 1.3 DaemonLauncher.ensureDaemonRunning() на Android — немедленный краш

**ПОДТВЕРЖДЕНО** — `lib/core/services/daemon_launcher.dart:68`:

```dart
_spawnedProcess = await Process.start(   // ← строка 68
  exePath,                               // 'C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe' (строка 28)
  [],
  mode: ProcessStartMode.detached,
);
```

На Android `dart:io` поддерживает `Process.start`, но:
1. `kIsWeb`-гард (строка 20) защищает только веб
2. **На Android APK нет бинарного файла mosaicd** — приложение работает в изолированной песочнице без Go-исполняемого файла
3. Нет ARM-бинаря mosaicd для Android
4. `Platform.resolvedExecutable` (строка 22) возвращает путь к виртуальной машине Dart

Единственный способ, которым `connect()` не завершится немедленно крашем, — если `_tryRealDaemon` вернёт `null` и `Process.start` завершится с исключением, которое `catch (_) {}` (строка 82) проглотит. Тогда провайдер вернёт `MockDaemonApi`, и нажатие «Connect» **не вызовет никаких ошибок, но и не установит VPN** — пользователь видит фиктивное «соединение».

### 1.4 Правильная архитектура для Android (для реализации)

```
Flutter UI
   │
   │  MethodChannel('mosaicvpn/tunnel')
   ▼
MosaicVpnService.kt  (extends android.net.VpnService)
   │  1. VpnService.prepare(ctx) → Intent → пользователь даёт согласие
   │  2. builder.establish() → ParcelFileDescriptor (TUN fd)
   │  3. передаёт fd через JNI/gomobile в sing-box/xray Go-ядро
   ▼
Go-ядро (gomobile: libmosaicd.aar)
   │  • получает TUN fd
   │  • читает/пишет IP-пакеты
   │  • устанавливает outbound-соединение с VPN-сервером
   └─ REST API доступен через localhost (внутри процесса) → никакого daemon.lock не нужно
```

**Обязательные изменения в AndroidManifest.xml:**
```xml
<uses-permission android:name="android.permission.BIND_VPN_SERVICE"/>

<service
    android:name=".MosaicVpnService"
    android:exported="false"
    android:permission="android.permission.BIND_VPN_SERVICE">
    <intent-filter>
        <action android:name="android.net.VpnService"/>
    </intent-filter>
</service>
```

**Обязательно создать:**
- `android/app/src/main/kotlin/ru/mosaicvpn/mosaic_vpn/MosaicVpnService.kt`
- `android/app/src/main/kotlin/ru/mosaicvpn/mosaic_vpn/TunnelManager.kt`
- Gradle-зависимость `libmosaicd.aar` (Go → gomobile bind → Android AAR)
- Обновить `MainActivity.kt` для регистрации `MethodChannel`

---

## 2. DESKTOP-ONLY ПЛАГИНЫ НА МОБИЛЬНЫХ УСТРОЙСТВАХ

### 2.1 `WindowListener` в типе `_AppShellState`

**ПОДТВЕРЖДЕНО** — `lib/app/app_shell.dart:42`:

```dart
class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver, WindowListener {  // ← строка 42
```

`WindowListener` — интерфейс из `package:window_manager`. Его класс **не существует на Android** на уровне плагина. Это означает:
- При сборке APK Dart компилятор включает код, который ссылается на нативный Android-плагин `window_manager`
- `window_manager` **не зарегистрирован** в `GeneratedPluginRegistrant.java` (только `file_picker`, `url_launcher`, `jni`)
- При первом обращении к `windowManager` кидается `MissingPluginException`

Вызовы, **НЕ** прикрытые `if (AppPlatform.isDesktop)`:
```dart
// строка 152-153 — в onWindowClose(), который для Android никогда не вызывается,
// но само наличие WindowListener в миксине рискованно при отражении
await windowManager.setPreventClose(false);
await windowManager.destroy();
```

Вызовы **КОРРЕКТНО** прикрытые:
```dart
// строка 131
if (AppPlatform.isDesktop) {
    windowManager.addListener(this);   // ← OK
}
// строка 139
if (AppPlatform.isDesktop) {
    windowManager.removeListener(this); // ← OK
}
```

**Вывод:** `TrayService.instance.init()` прикрыт гардом `!AppPlatform.isDesktop` (`tray_service.dart:43`), `main.dart` использует `if (AppPlatform.isDesktop)` — корректно. Однако `with WindowListener` в объявлении класса — потенциальный источник `MissingPluginException` на Android в ранних версиях Dart/Flutter, т.к. этот миксин может инициализировать нативный канал при создании объекта.

### 2.2 `screen_retriever` — транзитивная зависимость

**ПОДТВЕРЖДЕНО** — `linux/flutter/generated_plugin_registrant.cc` содержит `ScreenRetrieverLinuxPlugin`. Плагин подтягивается `window_manager` как зависимость. На Android не зарегистрирован.

---

## 3. DART:IO КОД, ЛОМАЮЩИЙСЯ НА ANDROID

### 3.1 Таблица всех нарушений

| Файл | Строка | Вызов | Гард | Поведение на Android |
|------|--------|-------|------|----------------------|
| `core/services/daemon_launcher.dart` | 22 | `Platform.resolvedExecutable` | нет (`kIsWeb` только) | возвращает путь к Dart VM, не exe |
| `core/services/daemon_launcher.dart` | 68 | `Process.start(exePath, ...)` | нет (`kIsWeb` только) | исключение поглощается `catch (_)` → mock API |
| `core/services/autostart_service.dart` | 63 | `Process.runSync('reg', ...)` | нет (только `Platform.isWindows`) | `UnsupportedError` — `reg` не существует |
| `core/services/autostart_service.dart` | 85 | `Process.runSync('reg', ...)` | нет | `UnsupportedError` |
| `core/services/autostart_service.dart` | 99 | `Process.runSync('reg', ...)` | нет | `UnsupportedError` |
| `core/services/autostart_service.dart` | 49 | `Platform.executable` | нет | возвращает путь Dart VM |
| `features/logs/logs_screen.dart` | 78 | `Process.start('explorer', ...)` | нет | `MissingPluginException` |
| `features/settings/settings_screen.dart` | 1537 | `Process.run('powershell', ...)` | нет | `ProcessException` |
| `features/settings/settings_screen.dart` | 1588 | `Process.start('powershell', ...)` | нет | `ProcessException` |
| `features/dashboard/dashboard_screen.dart` | 1683 | `Process.start('rundll32', ...)` | нет | `ProcessException` |
| `features/dashboard/dashboard_screen.dart` | 1954 | `Process.run('powershell', ...)` | нет | `ProcessException` |
| `features/dashboard/dashboard_screen.dart` | 2004 | `Process.start('powershell', ...)` | нет | `ProcessException` |
| `core/providers/vpn_providers.dart` | 39 | `Platform.isWindows` (без Android-ветки) | `kIsWeb` | Android попадает в `else` (Linux-ветка) — ищет `.mosaicvpn/daemon.lock` |

### 3.2 Вызов `AutostartService` без исключения Android

**ПОДТВЕРЖДЕНО** — `features/settings/settings_screen.dart:1386–1388`:

```dart
// _update() называется при любом изменении настроек (нет гарда платформы)
if (autoStart != null) {
  AutostartService.instance.setEnabled(autoStart != 'manual');  // строка 1388
}
```

`AutostartService.setEnabled()` (`autostart_service.dart:29`) — проверяет только `Platform.isWindows` / `Platform.isLinux`, Android не обрабатывается. Для Android метод вернёт `false` не падая, но только потому что `catch (_) {}` заглушит ошибку. Если `Platform.isAndroid` не перехватить явно, логика Windows-ветки при флаге `autoStart` будет вызвана (в теории — но `Platform.isWindows` вернёт `false` на Android).

---

## 4. ДЕФЕКТЫ РАЗМЕТКИ: СООТВЕТСТВИЕ СКРИНШОТАМ

### 4.1 Статус-бар перекрывает `_QuickStatusBar`

**ПОДТВЕРЖДЕНО** — `app_shell.dart:546`:

```dart
return Container(
  height: 48,                        // ← ФИКСИРОВАННАЯ высота
  // ...
  child: LayoutBuilder(
    builder: (context, constraints) {
      // ...
      return Row(  // ← Row без отступа для статус-бара Android
```

Мобильный Column (`app_shell.dart:334–350`) **НЕ обёрнут в `SafeArea`**:

```dart
: Column(         // ← нет SafeArea!
    children: [
      _QuickStatusBar(   // ← рисуется под статус-баром Android (24–28 dp)
        currentIndex: activeIndex,
```

Для сравнения — Desktop-ветка (строка 252) использует `SafeArea` для боковой панели, а мобильная — нет.

**Симптом скриншота:** статус-полоска приложения перекрывается системной статус-баром → пользователь не видит состояние VPN.

**Исправление:** обернуть Column мобильной ветки в `SafeArea(top: true)` или добавить `padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top)` к `_QuickStatusBar`.

### 4.2 `EdgeInsets.all(24)` — потеря 48 dp суммарно

**ПОДТВЕРЖДЕНО** — 16 экранов имеют жёсткий отступ:

| Файл | Строка |
|------|--------|
| `features/billing/billing_screen.dart` | 24 |
| `features/connections/connections_screen.dart` | 30 |
| `features/cores/cores_screen.dart` | 52 |
| `features/dashboard/dashboard_screen.dart` | 87 |
| `features/egresses/egresses_screen.dart` | 28 |
| `features/groups/groups_screen.dart` | 280, 308 |
| `features/logs/logs_screen.dart` | 119 |
| `features/profiles/profiles_screen.dart` | 21 |
| `features/provider_profile/provider_profile_screen.dart` | 35 |
| `features/routing/routing_screen.dart` | 22 |
| `features/servers/servers_screen.dart` | 69 |
| `features/settings/settings_screen.dart` | 52 |
| `features/speedtest/speedtest_screen.dart` | 32 |
| `features/stats/stats_screen.dart` | 73 |
| `features/subscriptions/subscriptions_screen.dart` | 24 |

На телефоне 360 dp: контент получает `360 - 24*2 = 312 dp`. Это само по себе нормально для большинства UI, но в связке с `Row` без `Flexible`/`Expanded` внутри создаёт переполнение.

**Симптом скриншота:** кнопки обрезаются у правого края экрана.

### 4.3 `SizedBox(height: 320, child: stationsPanel)` — фиксированная высота списка

**ПОДТВЕРЖДЕНО** — `dashboard_screen.dart:230`:

```dart
SizedBox(height: 320, child: stationsPanel),
```

На телефоне с высотой 640 dp экрана минус системные отступы (~56) минус `_QuickStatusBar` (48) минус BottomNav (~60) минус статус-бар (28) = ~448 dp. `connectionPanel` занимает ~120–150 dp, map AspectRatio 2:1 = ~156 dp, `SizedBox(320)` — итого выходит за пределы `SingleChildScrollView`, но это приемлемо, т.к. он scrollable. **Не критично, но 320 px — magic number**, на маленьких экранах список получается обрезанным.

### 4.4 `_QuickStatusBar` — `Row` с `SizedBox(width: 16)` без `Flexible`

**ПОДТВЕРЖДЕНО** — `app_shell.dart:571`:

```dart
Row(
  children: [
    Flexible(                 // ← StatusPill правильно обёрнут
      child: statusAsync.when(...),
    ),
    const SizedBox(width: 16),
    statusAsync.when(          // ← KillSwitchToggle — НЕ обёрнут ничем
      data: (status) => _KillSwitchToggle(status: status),  
    ...
    const Spacer(),
    statusAsync.when(          // ← QuickAction — НЕ обёрнут ничем
      data: (status) => status.state == 'connected'
          ? _QuickAction(label: 'Disconnect', ...)
          // ...
    ),
    const SizedBox(width: 8),
    IconButton(...)            // ← Settings
```

Компактный режим (строка 560: `final compact = constraints.maxWidth < 480`) сбрасывает текст кнопки `_QuickAction`, но сам виджет может быть шире, чем доступное пространство.

**Симптом скриншота:** `'DISCONNECTED'` разбивается на 2-строчный текст / буквы по одной в столбик — это происходит когда `_StatusPill` (`Flexible`) получает 0 px, потому что остальные виджеты в Row заняли всё место.

### 4.5 `SectionHeader` — вертикальный стек ниже 420 dp (УЖЕ ИСПРАВЛЕНО)

**ПОДТВЕРЖДЕНО (уже исправлено)** — `shared/widgets/atlas_widgets.dart:91–172`:

```dart
final isNarrow = constraints.maxWidth < 420;   // строка 97
return Column(
  children: [
    if (isNarrow) ...[
      Text(title, ...),
      if (subtitle != null) Text(subtitle!, ...),
      if (action != null) action!,    // ← action под заголовком
    ] else ...[
      Row(children: [
        Expanded(child: Text(title, ...)),
        if (action != null) action!,
      ]),
      ...
```

Это исправление правильное. До него `Row` без `Expanded` давал каждой букве только ~1–2 px ширины → `'S\nt\na\nt...'`. Теперь исправлено.

### 4.6 `cores_screen.dart` и `subscriptions_screen.dart` — высота 48 в диалогах

**ПОДТВЕРЖДЕНО**:
- `features/cores/cores_screen.dart:200` — `Container(height: 48, ...)` в заголовке
- `features/subscriptions/subscriptions_screen.dart:284` — `Container(height: 48, ...)` в поле ввода

Не критично, но на малых экранах могут конкурировать с системными отступами.

---

## 5. СТРАТЕГИЯ АДАПТИВНОСТИ: IS THERE A SYSTEM?

**ПОДТВЕРЖДЕНО - нет единой системы** — разрозненные точки останова:

| Значение | Файл | Строка | Назначение |
|----------|------|--------|------------|
| `420` | `shared/widgets/atlas_widgets.dart` | 97 | Вертикальный стек SectionHeader |
| `480` | `app_shell.dart` | 560 | Компактный режим QuickStatusBar |
| `600` | `app_shell.dart` | 201 | Переключение mobile/wide layout (shortestSide) |
| `600` | `features/dashboard/dashboard_screen.dart` | ~200 | Переключение 1-колонки/3-колонки |
| `720` | `features/account/account_screen.dart` | 90 | maxWidth ограничение |
| `900` | `features/groups/groups_screen.dart` | 25 | 2-колоночная сетка |

**Проблемы:**
1. `app_shell.dart` использует `size.shortestSide > 600` (абсолютные dp устройства), но `dashboard_screen.dart` использует `constraints.maxWidth < 600` (ширина контента без sidebar). Эти два числа **не эквивалентны**: боковая панель занимает 72 dp, поэтому dashboard получает `(360 + 72 - 72) = 360 dp` — ok, но может создавать расхождения на планшетах.
2. `SectionHeader` переключается при `420` dp, `QuickStatusBar` при `480` dp — два разных компонента, которые «видят» разные размеры.

**Предложение:** создать `lib/core/layout/breakpoints.dart`:
```dart
class Breakpoints {
  static const double compact = 420;    // один столбец, без action-кнопок
  static const double mobile = 600;     // BottomNav vs Sidebar
  static const double tablet = 900;     // многоколоночные сетки
  static const double desktop = 1200;   // максимальная ширина контента 720px
}
```

---

## 6. НАВИГАЦИЯ: НЕДОСТУПНЫЕ ЭКРАНЫ НА ТЕЛЕФОНЕ

### 6.1 Desktop Sidebar vs Mobile BottomNav

**ПОДТВЕРЖДЕНО** — `app_shell.dart`:

**Desktop `_destinations`** (16 пунктов, строки 66–121):
Dashboard, Stations, Profiles, Subscriptions, Billing, Groups, Account, Provider, Routes, Egresses, Activity, Stats, Speed Test, Cores, Logs, Settings

**Mobile `_mainDestinations`** (5 пунктов, строки 47–64):
Dashboard, Groups, Subscriptions, Billing, **More**

**`MoreScreen`** (`features/more/more_screen.dart`) содержит все недостающие экраны через `Navigator.push()` — Account, Stations, Profiles, Provider, Routes, Egresses, Activity, Stats, Speed Test, Cores, Logs, Settings.

### 6.2 Итоговый статус

Через «More» → `Navigator.push` все экраны **технически доступны** на мобильных. Однако:

- Экраны пушатся с `Scaffold + AppBar` оберткой, **но без `SafeArea`** в pushed-экране (у pushed-экрана нет `SafeArea`, потому что Scaffold `appBar` сам выставляет top-padding — это нормально).
- Экраны после push получают `padding: EdgeInsets.all(24)` от своей Padding, которая расположена **внутри** Scaffold body — это корректно.

**Что реально недоступно на мобильных без "More":**
- Прямой доступ через BottomNav: только 4 реальных экрана + More
- Из MoreScreen Settings открывается через push, но не как tab — это неудобно, но работает

**Критическая проблема навигации:** При нажатии настроек через `_QuickStatusBar` (settings-иконка, строка 622–629):
```dart
Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => const SettingsScreen()),
);
```
Этот путь работает, но SettingsScreen внутри попытается вызвать `AutostartService.setEnabled()` (строка 1388) без проверки платформы.

---

## 7. ТЕСТОВОЕ ПОКРЫТИЕ

### 7.1 Существующие тесты

| Файл | Что проверяет | Ширина экрана |
|------|--------------|---------------|
| `test/widget_test.dart` | AppShell: 5 tabs, layout overflow | 390×844, 360×640 |
| `test/features/dashboard_desktop_test.dart` | Desktop layout, footer note | 1440×900 |
| `test/features/station_row_test.dart` | Name width stability, latency badge | 1600×1000 |
| `test/features/account_screen_test.dart` | Account layout overflow | 360×640 |
| `test/billing_test.dart` | Billing logic | нет |
| `test/world_map_test.dart` | Map camera | нет |
| `test/theme_guard_test.dart` | Theme | нет |

### 7.2 Анализ

**`widget_test.dart`** тестирует `AppShell` на 360×640 — это **правильно**, но:
- Не проверяет, что `_QuickStatusBar` не перекрыт (нет проверки `MediaQuery.padding.top`)
- Не проверяет, что `SafeArea` присутствует
- `MockDaemonApi` возвращает `VpnStatus()` — нет `Process` вызовов

**Отсутствующий тест, который поймал бы баги скриншотов:**

```dart
// Этого теста НЕТ:
testWidgets('DISCONNECTED status text does not wrap on 320px phone', (tester) async {
  tester.view.physicalSize = const Size(320, 568);  // iPhone SE
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  // ... pump AppShell ...

  // Ищем текст статуса
  final statusText = find.textContaining('DISCONNECTED');
  final size = tester.getSize(statusText);
  // Должен быть одной строкой, а не 12 строками
  expect(size.height, lessThan(30), reason: 'DISCONNECTED wraps letter-by-letter');
});

testWidgets('QuickStatusBar not overlapped by system status bar', (tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 3.0;
  tester.binding.platformDispatcher.textScaleFactorTestValue = 1.0;
  // mediaQuery.padding.top должен быть учтён
  // ...
});
```

---

## 8. iOS / MACOS: ОТСУТСТВИЕ И ТРЕБОВАНИЯ

### 8.1 Подтверждение отсутствия

**ПОДТВЕРЖДЕНО** — директории `ios/` и `macos/` **отсутствуют** в `flutter/`.

### 8.2 Что нужно для iOS

**Техническое:**
1. `flutter create --platforms=ios .` — генерирует `ios/` директорию
2. Xcode 15+ и macOS для сборки (на Windows невозможно без CI/macOS runner)
3. **Network Extension entitlement** (`com.apple.developer.networking.networkextension`) — только через Developer Program ($99/год)
4. **Personal VPN entitlement** (`com.apple.developer.networking.vpn-api`) — требует отдельного запроса у Apple для сторонних App Store приложений
5. Провайдер туннеля: `NEPacketTunnelProvider` (аналог `VpnService`)
6. Go-ядро: собрать через `gomobile bind -target ios` → `.framework`
7. `NEVPNManager` для управления профилями
8. Signing: provisioning profile с VPN capabilities

**App Store ограничения:**
- Приложения VPN в App Store требуют **специального обоснования** для Apple
- Без правильного entitlement `NEPacketTunnelProvider` — App Store отклонит
- **Категория приложения:** «Utilities / VPN» — проходит ревью, но занимает 1–3 недели

**Оценка усилий:** 4–8 недель (Senior iOS + Go разработчик), не считая Apple review.

### 8.3 Что нужно для macOS

1. `flutter create --platforms=macos .` — генерирует `macos/`
2. **System Extension** (для современного macOS 10.15+) или старый `NETunnelProviderManager`
3. Entitlement: `com.apple.developer.system-extension.install` + VPN entitlements
4. Нотаризация через Apple (Gatekeeper)
5. Homebrew-распространение возможно, App Store — те же VPN ограничения

**Оценка усилий:** 2–4 недели.

---

## 9. LINUX / WINDOWS: СПЕЦИФИЧЕСКИЕ ПРОБЛЕМЫ

### 9.1 Windows

**Жёстко захардкоженный путь:**
- `daemon_launcher.dart:28`: `r'C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe'` — путь конкретного разработчика, не работает у других пользователей
- `autostart_service.dart:83`: `r'"C:\Users\ANEN\mosaicvpn\flutter\build\windows\x64\runner\Debug\mosaic_vpn.exe"'` — hardcode dev-пути в production-коде

**TUN-режим требует Admin:**
- `dashboard_screen.dart:1954` и `settings_screen.dart:1537` — `Process.run('powershell', [...'IsInRole...Administrator'])` — проверка прав
- `Process.start('powershell', ['-Command', 'Start-Process -FilePath "$exePath" -Verb RunAs'])` — правильный UAC-запрос, но только для Windows; нет гарда `Platform.isWindows`

### 9.2 Linux

**ПОДТВЕРЖДЕНО** — `generated_plugin_registrant.cc` включает:
- `screen_retriever_linux_plugin` (транзитивная зависимость `window_manager`)
- `system_tray_plugin`
- `window_manager_plugin`

`AutostartService` для Linux (`autostart_service.dart:19–55`):
```dart
} else if (Platform.isLinux) {
  final file = File(
    '${Platform.environment['HOME']}/.config/autostart/mosaic-vpn.desktop');
  // ...
  Exec=${Platform.executable}   // ← строка 49: указывает на бинарь Dart VM в dev-режиме
```

В production Flutter-сборке `Platform.executable` возвращает путь к скомпилированному бинарю — нормально. Но в dev-режиме это `dart` или Flutter Runner — неверно.

**TUN на Linux:** требует `CAP_NET_ADMIN` или `sudo`. Проверка на Linux не реализована (только Windows-ветка с PowerShell).

---

## ПРИОРИТИЗИРОВАННЫЙ СПИСОК ПРОБЛЕМ

### P0 — Продукт лжёт пользователям / не работает

| # | Проблема | Местонахождение | Одноstрочное исправление |
|---|----------|-----------------|--------------------------|
| P0-1 | Android не устанавливает VPN-туннель (нет `VpnService`, нет демона, нет TUN fd) | `AndroidManifest.xml`, `daemon_launcher.dart:68` | Реализовать `MosaicVpnService.kt` + gomobile + MethodChannel (см. §1.4) |
| P0-2 | `with WindowListener` — class из desktop-only плагина в типе AppShell | `app_shell.dart:42` | Переместить WindowListener в отдельный `_DesktopWindowObserver` mixin, активируемый только при `isDesktop` |
| P0-3 | `Process.start(mosaicd.exe)` на Android — silently falls back to MockDaemonApi | `daemon_launcher.dart:68` | Добавить `if (kIsWeb || AppPlatform.isMobile) return false;` в `ensureDaemonRunning()` |

### P1 — Сломанный UX

| # | Проблема | Местонахождение | Одностр. исправление |
|---|----------|-----------------|----------------------|
| P1-1 | Статус-бар Android перекрывает QuickStatusBar (48 dp без SafeArea) | `app_shell.dart:334` | Обернуть мобильный `Column` в `SafeArea(top: true, child: ...)` |
| P1-2 | `Process.start('explorer', ...)` без гарда в LogsScreen | `logs_screen.dart:78` | Обернуть в `if (AppPlatform.isDesktop && Platform.isWindows)` |
| P1-3 | `Process.run('powershell', ...)`, `Process.start('powershell', ...)` без гарда | `dashboard_screen.dart:1954,2004`; `settings_screen.dart:1537,1588` | Добавить `if (!AppPlatform.isDesktop || !Platform.isWindows) return;` |
| P1-4 | `Process.start('rundll32', ...)` без гарда | `dashboard_screen.dart:1683` | Добавить `if (!AppPlatform.isDesktop || !Platform.isWindows) return;` |
| P1-5 | `AutostartService.setEnabled()` вызывается без проверки платформы | `settings_screen.dart:1388` | Обернуть `if (AppPlatform.isDesktop) AutostartService...` |
| P1-6 | Hardcode `C:\Users\ANEN\mosaicvpn\...` в production-коде | `daemon_launcher.dart:28`; `autostart_service.dart:83` | Удалить hardcoded пути разработчика |
| P1-7 | `_StatusPill` в `Flexible` + `Spacer` → при переполнении Row текст сжимается побуквенно | `app_shell.dart:571–605` | Ограничить min-width `_KillSwitchToggle` и `_QuickAction` |

### P2 — Полировка

| # | Проблема | Местонахождение | Одностр. исправление |
|---|----------|-----------------|----------------------|
| P2-1 | 6 разных breakpoint-констант без единого источника | 6 файлов | Создать `lib/core/layout/breakpoints.dart` |
| P2-2 | `EdgeInsets.all(24)` — не адаптируется | 16 файлов | Заменить на `EdgeInsets.symmetric(horizontal: adaptive, vertical: 16)` |
| P2-3 | `SizedBox(height: 320, child: stationsPanel)` — magic number | `dashboard_screen.dart:230` | Использовать `Expanded` или `FractionallySizedBox` |
| P2-4 | Нет теста для wrapping текста статуса на 320 dp экране | `test/` | Добавить phone-width тест для `_StatusPill` |
| P2-5 | Linux TUN — нет проверки `CAP_NET_ADMIN` | `settings_screen.dart` | Добавить `pkexec`/`polkit` проверку для Linux |

---

## СТАТУС ИЗМЕНЁННЫХ ФАЙЛОВ (uncommitted)

### `flutter/lib/app/app_shell.dart`
**ПОДТВЕРЖДЕНО** — строка 201:
```dart
final shortest = mq.size.shortestSide;
final isWide = shortest > 600;   // ← изменено с size.width > 900 на shortestSide > 600
```
Изменение **семантически правильное**: `shortestSide` гарантирует, что телефон в ландшафтном режиме не получает desktop-layout. На iPhone SE (568×320) `shortestSide = 320 < 600` → мобильный layout в любой ориентации.

### `flutter/lib/shared/widgets/atlas_widgets.dart`
**ПОДТВЕРЖДЕНО** — `SectionHeader` теперь использует `LayoutBuilder` с `isNarrow = constraints.maxWidth < 420`:
- При узком экране: заголовок + subtitle + action-кнопка выстраиваются вертикально
- При широком: заголовок + action в Row с `Expanded`

Изменение **корректно исправляет** симптом «S\nt\na\nt...» из скриншотов.

---

## ДОПОЛНИТЕЛЬНЫЕ ЗАМЕЧАНИЯ

1. **`_candidateLockfilePaths()`** (`vpn_providers.dart:39`) — на Android попадает в ветку `else` (Linux), ищет `~/.local/share/mosaicvpn/daemon.lock` — этот путь не существует на Android → fallback к MockDaemonApi.

2. **`zxing_lib` и `image`** в pubspec — QR-декодирование. Оба pure-Dart, работают на Android. ✅

3. **`path_provider: ^2.1.4`** (используется в `logs_screen.dart` через `getApplicationDocumentsDirectory()`) — на Android возвращает `/data/data/ru.mosaicvpn.mosaic_vpn/files/` — корректно. ✅

4. **`file_picker: ^8.1.4`** — зарегистрирован в `GeneratedPluginRegistrant.java` — корректно для Android. ✅

5. **`fl_chart`, `flutter_svg`, `intl`, `collection`** — всё pure-Flutter, платформо-независимо. ✅

6. **Минимальный SDK Android** (`build.gradle.kts:18`): `minSdk = flutter.minSdkVersion` — обычно Flutter устанавливает minSdk=21 (Android 5.0). `VpnService` доступен с API 14, так что ограничений нет.
