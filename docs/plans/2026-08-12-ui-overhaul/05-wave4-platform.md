# Волна 4 — Платформа: Android-туннель и гарды

> Независима от волн 1–3, можно вести параллельно.
> T4.1 — самая крупная задача всего плана (3–5 дней). T4.2–T4.4 быстрые.

---

## T4.1 — Android VpnService: реальный туннель

**Приоритет:** P0 (продукт врёт пользователю). **Оценка:** 3–5 дней. **Риск:** высокий.
**Это НЕ задача для одного субагента одним заходом.** Разбита на 5 подзадач с проверкой
после каждой.

### Диагноз

✅ VERIFIED: `flutter/android/app/src/main/AndroidManifest.xml` содержит только
`INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`.
Нет `BIND_VPN_SERVICE`, нет `<service>`, нет `VpnService`. Нативного кода — только
`MainActivity.kt` (`ru.mosaicvpn.mosaic_vpn`) и `GeneratedPluginRegistrant.java`.

⚠️ SUBAGENT: `daemon_launcher.dart:68` вызывает `Process.start('mosaicd.exe')` без
Android-гарда → `ProcessException` → клиент молча сваливается в `MockDaemonApi` → **UI
показывает «Connected» при нулевом туннеле.**

### Почему это не «дописать пару строк»

На десктопе архитектура такая: Flutter GUI ↔ HTTP ↔ отдельный процесс `mosaicd` ↔ sing-box.
На Android **отдельных процессов не бывает** — приложение не может форкнуть демона. Ядро
sing-box должно жить **внутри** приложения как библиотека, а туннель поднимается через
системный `VpnService`, который отдаёт файловый дескриптор TUN-интерфейса.

То есть меняется не манифест, а способ, которым клиент разговаривает с ядром.

### T4.1.1 — Собрать Go-ядро в Android-библиотеку (1 день)

1. Установить `gomobile`, `gomobile init`, NDK.
2. Создать пакет-обёртку `mobile/` в Go-репозитории с экспортируемым API:
```go
package mobile
// Start принимает конфиг sing-box в JSON и fd TUN-интерфейса от VpnService.
func Start(configJSON string, tunFd int) error
func Stop() error
func Status() string   // JSON
func Stats() string    // JSON: rx/tx/latency
```
   Ограничение gomobile: экспортировать можно только простые типы (string, int, bool,
   []byte) — поэтому обмен через JSON, а не структуры.
3. Собрать: `gomobile bind -target=android -androidapi 24 -o mosaiccore.aar ./mobile`
4. Положить `.aar` в `flutter/android/app/libs/`, подключить в `build.gradle.kts`.

**Приёмка:** `.aar` существует, размер в отчёте (ожидаемо 15–30 МБ на все ABI — это ляжет
в размер APK, зафиксировать). Проект собирается: `flutter build apk --debug`.

### T4.1.2 — MosaicVpnService.kt (1 день)

1. `android/app/src/main/kotlin/ru/mosaicvpn/mosaic_vpn/MosaicVpnService.kt`:
   наследник `VpnService`; `Builder` с `addAddress`, `addRoute`, `addDnsServer`, `setMtu`;
   `establish()` → `ParcelFileDescriptor`; fd передать в `mosaiccore.Start()`.
2. Foreground-нотификация **обязательна** — без неё Android убьёт сервис через минуты.
   Канал уведомлений, `startForeground()` с типом `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`
   (или `..._SYSTEM_EXEMPTED` в зависимости от целевого API).
3. Корректная остановка: `Stop()` в ядре → закрыть fd → `stopForeground` → `stopSelf`.
4. `onRevoke()` — система может отозвать разрешение VPN (например, пользователь подключил
   другой VPN): обработать, иначе приложение останется в состоянии «подключено» без туннеля.

**Приёмка:** сервис стартует, в шторке видна нотификация, `adb shell dumpsys connectivity`
показывает активный VPN-интерфейс. Вывод команды — в отчёт.

### T4.1.3 — Манифест и разрешения (2 ч)

```xml
<service
    android:name=".MosaicVpnService"
    android:permission="android.permission.BIND_VPN_SERVICE"
    android:foregroundServiceType="specialUse"
    android:exported="false">
    <intent-filter>
        <action android:name="android.net.VpnService"/>
    </intent-filter>
</service>
```
Плюс `POST_NOTIFICATIONS` (уже есть), `FOREGROUND_SERVICE` (есть),
`FOREGROUND_SERVICE_SPECIAL_USE`.

**Приёмка:** `grep -c "BIND_VPN_SERVICE" AndroidManifest.xml` → 1.

### T4.1.4 — MethodChannel и развилка в Dart (1 день)

1. Канал `ru.mosaicvpn/tunnel`: методы `prepare`, `connect(config)`, `disconnect`, `status`;
   EventChannel `ru.mosaicvpn/tunnel_events` для стрима статуса и статистики.
2. `VpnService.prepare()` возвращает `Intent`, который надо показать пользователю при первом
   подключении (системный диалог «разрешить VPN»). Обработать отказ: если пользователь
   отказал — честно показать «разрешение не выдано», не «ошибка подключения».
3. В Dart: `DaemonApi` — уже абстракция (`daemon_api_base.dart`). Добавить
   `ChannelDaemonApi implements DaemonApi`, выбирать в провайдере через существующий
   `AppPlatform.isMobile`.
4. **Убрать `MockDaemonApi` из production-пути.** Mock допустим только в тестах. Сейчас он
   маскирует отсутствие туннеля под успешное подключение — это худшее из возможных
   поведений для VPN.

**Приёмка:** на реальном устройстве/эмуляторе подключение поднимает туннель; `curl ifconfig.me`
через приложение отдаёт IP сервера, а не домашний. **Это единственная настоящая проверка** —
всё остальное косвенно.

### T4.1.5 — Проверка на устройстве (0.5 дня)

Обязательный чек-лист (каждый пункт с выводом команды):
- [ ] `adb shell dumpsys connectivity | grep -i vpn` — интерфейс активен
- [ ] внешний IP меняется на IP сервера
- [ ] нотификация не пропадает при свёрнутом приложении > 10 мин
- [ ] переключение Wi-Fi ↔ мобильные данные не рвёт туннель насмерть
- [ ] `onRevoke` при подключении другого VPN обработан
- [ ] отзыв разрешения в настройках системы приводит к честному «disconnected»
- [ ] расход батареи за час в фоне — приблизительно, для понимания порядка

**НЕ ДЕЛАТЬ:** не заявлять успех по логам приложения. Только по системным данным Android.

---

## T4.2 — Гарды платформы: убрать 6 незащищённых Process-вызовов

**Приоритет:** P0. **Оценка:** 3 ч.

**Проблема** ✅ VERIFIED (5 файлов) + ⚠️ SUBAGENT (6 вызовов):
```
lib/core/services/autostart_service.dart
lib/core/services/daemon_launcher.dart
lib/features/dashboard/dashboard_screen.dart
lib/features/logs/logs_screen.dart
lib/features/settings/settings_screen.dart
```
Windows-команды `explorer`, `rundll32`, `powershell`, `reg` без проверки платформы.
На Android — `ProcessException`.

**Шаги.**
1. Каждый вызов обернуть в `if (AppPlatform.isDesktop)`; на мобиле — либо альтернатива
   (`url_launcher` для открытия ссылок), либо пункт вообще отсутствует в UI.
2. `daemon_launcher.dart` — целиком не вызывать на мобиле: там нет демона по архитектуре.
3. **Guard-тест** `test/platform_guard_test.dart`: запретить `Process.run`/`Process.start`
   в `lib/features/` вообще. Процессы — дело `core/services/`, и там они гейтятся. Тест
   валит сборку при возврате такого кода в экраны.

**Приёмка:** `grep -rn "Process.run\|Process.start" lib/features/` → **пусто**;
guard-тест зелёный.

---

## T4.3 — Убрать хардкод пути разработчика

**Приоритет:** P1. **Оценка:** 30 мин.

✅ VERIFIED: `daemon_launcher.dart:28-29` содержит
`r'C:\Users\ANEN\mosaicvpn\bin\mosaicd.exe'`. У любого другого пользователя — мёртвая ветка
поиска. Плюс это утечка имени пользователя в бинарник.

Оставить: `$appDir\mosaicd.exe`, `$appDir\bin\mosaicd.exe`,
`C:\Program Files\MosaicVPN\...`, `%LOCALAPPDATA%\MosaicVPN\...`.

**Приёмка:** `grep -rn "ANEN" lib/` → **пусто**.

---

## T4.4 — Desktop-only плагины: аудит всех вызовов

**Приоритет:** P1. **Оценка:** 2 ч.

`system_tray ^2.0.3`, `window_manager ^0.4.3` + транзитивный `screen_retriever` —
desktop-only ✅ VERIFIED (в pubspec). На Android любой их вызов даёт
`MissingPluginException`.

**Шаги.**
1. Найти все вызовы: `grep -rn "systemTray\|SystemTray\|windowManager\|WindowManager\|screenRetriever" lib/`
2. Каждый — под `AppPlatform.isDesktop`.
3. `_AppShellState with WindowListener` — см. T3.1, вынести в desktop-контроллер.
4. Guard-тест: запретить импорт `package:system_tray` и `package:window_manager` вне
   `lib/core/platform/` и `lib/app/shell/desktop_*.dart`.

**Приёмка:** guard-тест зелёный; на Android в логах нет `MissingPluginException`
(`adb logcat | grep MissingPlugin` → пусто после прохода по всем экранам).
