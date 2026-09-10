# Релиз MosaicVPN v0.3.54

**Дата**: 9 сентября 2026 г.  
**Платформы**: Android, Windows, Linux, Web  
**Архитектурный рецензент**: Claude Opus 5 High (OmniRoute AI Gateway)  
**Инженер-исполнитель**: Gemini (Hands & Eyes)

---

### 1. Android Quick Settings Tile & VpnService Lifecycle (Hardening)
- **API Guarding**:
  - Добавлена безопасная обработка методов `tile.subtitle` (Android 10+ / API 29) и `tile.stateDescription` (Android 11+ / API 30) с `runCatching`/`try-catch`, исключающая `NoSuchMethodError` на устройствах с Android 7.0–9.0 (API 24–28).
- **Service Lifecycle & Revocation**:
  - Реализован обработчик `onRevoke()` в `MosaicVpnService` для корректного сброса состояния и уведомления системы при отзыве прав VPN пользователем или сторонним приложением.
  - Установлен возврат `Service.START_NOT_STICKY` в `onStartCommand` для предотвращения автоматического перезапуска сервиса в зомби-состоянии с `intent == null` после OOM-kill.
  - Интегрирован вызов `TileService.requestListeningState` при событиях подключения (`connected`) и отключения (`stopForeground/stopSelf`), обеспечивающий мгновенное обновление иконки в шторке.
- **Интерактивные действия в уведомлении**:
  - В постоянное уведомление Android добавлена кнопка «Отключить» (`ACTION_STOP`), использующая отдельный `PendingIntent` с флагом `FLAG_IMMUTABLE`.
  - Устранена гонка при одновременном вызове `ACTION_STOP` из системного уведомления, шторки быстрых настроек и UI Flutter.
- **Защита фонового запуска**:
  - Все вызовы `MosaicVpnService.stop()` и запуск активности из `MosaicVpnTileService.onClick()` обернуты в `runCatching` для защиты от `BackgroundServiceStartNotAllowedException` на Android 12+.

---

### 2. Динамическое тестирование сетевой задержки (Latency Probes)
- **Снятие ограничений на проверку прямого маршрута**:
  - Разблокирован пинг для маршрута `direct` через специализированный прямой TCP-хэндшейк.
- **Пользовательский интерфейс проверки задержки**:
  - В `groups_screen.dart` интегрирован визуальный спиннер `CircularProgressIndicator` и отображение процентной шкалы прогресса для многораундового пинга.
- **Тонкая настройка пинга в настройках приложения**:
  - Параметры пинга вынесены в модель `Preferences` и экран настроек: количество раундов (1–10), таймаут (1.0–10.0 с) и выбор протокола (URL test, TCP handshake, ICMP).

---

### 3. Стартовый диалог обновлений (`AppUpdateService`)
- Добавлен сервис проверки релизов с GitHub API.
- Реализован диалог обновления с чекбоксом «Больше не напоминать для этой версии».
- Выбор пользователя сохраняется в `SharedPreferences` (`mosaic_skip_update_version`) с семантическим сравнением версий.

---

### 4. Дизайн-система Atlas Zen & Соответствие Theme Guard
- Устранены все 21 нарушение правила жестко заданных цветов (`theme_guard_test.dart`):
  - В `atlas_onboarding_card.dart`, `atlas_route_picker_sheet.dart`, `connection_dashboard.dart` и `onboarding_wizard.dart` литералы заменены на семантические токены `c.onAccent`, `c.success`, `c.successDim`, `c.borderInk`, `c.warning`, `c.info`.
- Предотвращено переполнение макета (`RenderFlex overflowed`) на узких экранах смартфонов (360dp–390dp) в `_buildCompactStatsRow` через адаптивный `Wrap`.

---

### 5. Результаты верификации и тестирования
- **`dart analyze lib/`**: 0 ошибок, 0 предупреждений (`No issues found!`).
- **Модульные и интеграционные тесты**: 92 из 92 тестов успешно пройдены (100% PASS).
- **Сборка Android APK (`app-debug.apk`)**: успешно собрана в изолированном Docker-песочнице `devin-sandbox` с включением нативного `libbox.so`.
- **Проверено архитектурным анализом**: Claude Opus 5 High (OmniRoute `opus-5`).
