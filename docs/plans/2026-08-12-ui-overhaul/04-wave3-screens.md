# Волна 3 — Переверстка экранов

> **Зависит от волны 1.** T3.2 (дашборд) дополнительно зависит от волны 2.
> Задачи T3.1–T3.9. Максимум 3 экрана параллельно — иначе конфликты в `shared/`.

---

## Правило для всех задач волны 3

Каждый экран переверстывается по одному сценарию. Отклонения — только с обоснованием в отчёте.

1. **Расслоить, если файл > 600 строк.** Вынести приватные виджеты в
   `features/<name>/widgets/`. Один класс — один файл. Это предусловие, а не «потом»:
   переверстать монолит на 2000 строк аккуратно нельзя.
2. **Заменить все литералы** на токены `AtlasSpace` / `AtlasType` / `AtlasBreak`.
3. **Собрать из компонентов** `shared/widgets/atlas/` (волна 1, T1.5), не изобретать свои
   карточки и пустые состояния.
4. **Четыре компоновки:** narrow / phone / tablet / desktop. Не «одна адаптивная» —
   явные ветки, читаемые глазами.
5. **`Semantics`** на каждый интерактивный элемент и на каждый блок с данными.
6. **`SafeArea`** для мобильных ветвей — иначе статус-бар Android наезжает на содержимое
   (это второй симптом со скриншотов пользователя).
7. **Golden-тесты** на 320 / 360 / 768 / 1280.
8. **Проверка `textScaler`:** прогнать экран при масштабе текста 1.0 и 1.3. Сейчас в проекте
   **ноль** обработки масштаба ✅ VERIFIED, а 1.3 — частая системная настройка на Android.
9. **Скриншот до/после** в отчёте. Обязательно: пробники не ловят обрезку текста краем,
   повтор цвета и дрожь в 1px — только глаза на A/B-диффе.

---

## T3.1 — Расслоить app_shell и добавить SafeArea

**Приоритет:** P0 для UX. **Оценка:** 4 ч. **Файл:** `lib/app/app_shell.dart` (810 строк).

**Уже исправлено в рабочей копии** (не закоммичено, подтверждено субагентом как корректное):
breakpoint `size.width > 900` → `shortestSide > 600`. Не откатывать.

**Проблемы.**

1. `app_shell.dart:334` — мобильная ветка **без `SafeArea`** ⚠️ SUBAGENT: `_QuickStatusBar`
   уходит под статус-бар Android. Это ровно то, что видно на скриншоте пользователя, где
   «Disconnected / Kill Switch / QuickConnect» слиплись с системными иконками и временем.
2. `app_shell.dart:42` — `_AppShellState with WindowListener` ⚠️ SUBAGENT: mixin из
   **desktop-only** плагина `window_manager` вшит в тип мобильной оболочки. На Android это
   мина: любой вызов метода миксина даёт `MissingPluginException`.
3. `app_shell.dart:546` — `_QuickStatusBar` с `height: 48` ✅ VERIFIED: фиксированная высота
   при `textScaler` 1.3 обрежет содержимое.
4. Вся навигация, шорткоты, статус-бар и автоподключение в одном файле на 810 строк.

**Шаги.**

1. Разнести: `app/shell/app_shell.dart` (только компоновка), `app/shell/quick_status_bar.dart`,
   `app/shell/side_rail.dart`, `app/shell/bottom_nav.dart`, `app/shell/shortcuts.dart`,
   `app/shell/auto_connect.dart`.
2. `SafeArea(top: true, bottom: true)` для мобильной ветки. Для десктопной не нужен.
3. `WindowListener` вынести в отдельный `DesktopWindowController`, подключаемый **только**
   при `AppPlatform.isDesktop`. Мобильная оболочка не должна знать о существовании
   `window_manager`.
4. `height: 48` → `ConstrainedBox(minHeight: 48)` + вертикальные отступы токенами.
5. `_QuickStatusBar` при narrow: статус-пилюля + kill switch в строку, действия — иконками
   без подписей (это частично сделано через `compact`, довести).

**Приёмка:**
- скриншот Android 360dp: между системным статус-баром и содержимым есть зазор
- `grep -n "with WindowListener" lib/app/` → **пусто**
- `flutter test` зелёный; `grep -rn "height: 48" lib/app/` → пусто

---

## T3.2 — Дашборд: расслоить и переверстать

**Приоритет:** P0 для UX. **Зависит от:** волна 1 + волна 2. **Оценка:** 8 ч.
**Файл:** `lib/features/dashboard/dashboard_screen.dart` (2074 строки ✅ VERIFIED).

**Проблемы со скриншотов пользователя:**

| Симптом на скриншоте | Причина в коде |
|---|---|
| «DI/SC/O/N/NE/CT/ED» в столбик | панель получает ~120dp, крупный текст без `FittedBox` |
| «Enga/ge Tu/nnel» ломается | кнопка с фиксированным текстом в узкой колонке |
| «N o S o u r c e s» по букве | пустое состояние в колонке шириной ~100dp |
| карта — вертикальный мазок | `AspectRatio(2.0)` при ширине 336dp → высота 168dp (T2.5) |
| статус-бар наезжает | нет `SafeArea` (T3.1) |
| кнопки обрезаны краем | `Row` без `Wrap` в тулбаре |

**Шаги.**

1. Расслоить 2074 строки на `features/dashboard/widgets/`:
   `connection_panel.dart`, `world_chart_panel.dart`, `stations_panel.dart`,
   `station_row.dart`, `metric_grid.dart`, `engage_button.dart`.
   Логику GeoIP вынести в `features/dashboard/geoip_controller.dart` — она не про вёрстку.
2. Компоновки:
   - **narrow:** одна колонка. Порядок: статус подключения крупно → кнопка Engage на всю
     ширину → метрики 2×2 → строка «Карта · N станций ›» → список станций.
     Карта скрыта (T2.5).
   - **phone:** одна колонка, карта 16:9 после метрик.
   - **tablet:** две колонки (подключение+метрики | карта+станции).
   - **desktop:** три колонки, как сейчас.
3. `AtlasMetric` с `FittedBox(fit: BoxFit.scaleDown)` для крупного статуса — лечит
   «DISCONNECTED» в столбик на уровне компонента, а не подпоркой в одном месте.
4. Кнопка Engage: `minWidth` + текст в одну строку с `TextOverflow.fade`; при narrow —
   на всю ширину.
5. Пустое состояние станций — через `AtlasEmptyState`.
6. **Проверить `MockDaemonApi`:** ⚠️ SUBAGENT утверждает, что при недоступном демоне клиент
   молча показывает фиктивное подключение. Убедиться, что UI честно показывает «демон
   недоступен», а не «Connected». Это про доверие, не про вёрстку, но правится здесь.

**Приёмка:**
- скриншоты 320/360/390/768/1280 — ни одного разрыва слова, ни одного overflow
- `wc -l lib/features/dashboard/dashboard_screen.dart` → **< 400**
- `flutter test test/features/dashboard_desktop_test.dart` + новый мобильный тест зелёные

---

## T3.3 — Экран станций (Stations & Sources)

**Приоритет:** P0 для UX. **Оценка:** 6 ч.
**Файл:** `lib/features/servers/servers_screen.dart` (1765 строк ✅ VERIFIED).

**Это экран с самого первого скриншота пользователя** — где «Station» и «Sources» рассыпались
по одной букве в строку.

**Причина** ✅ VERIFIED: `servers_screen.dart:74-78` — `SectionHeader` с `action`, внутри
которого `SingleChildScrollView(scrollDirection: Axis.horizontal)` с четырьмя кнопками
(«Add Source», «Add Server», «New Group», «Test All»). `SectionHeader` в старой версии
клал title и action в один `Row` с `Expanded` на title → на 360dp заголовку оставалось
~40dp → перенос по букве.

**Частично исправлено в рабочей копии:** `SectionHeader` теперь при `maxWidth < 420`
складывает title и action вертикально. Это лечит симптом. Осталось убрать причину —
четыре кнопки в ряд на телефоне.

**Шаги.**

1. Расслоить 1765 строк: `widgets/station_group_tile.dart`, `widgets/station_row.dart`,
   `widgets/station_toolbar.dart`, `widgets/station_search_bar.dart`,
   `widgets/station_context_menu.dart`.
2. Тулбар через `AtlasToolbar`: при narrow — одна главная кнопка «Add Source» на всю ширину,
   остальные три в меню «⋯». Не горизонтальный скролл: пользователь не догадается, что там
   что-то есть справа.
3. Поиск и сортировка: при narrow — в столбик, поле на всю ширину.
4. Строка станции через `AtlasListRow`: при narrow двухстрочно — имя + флаг сверху,
   задержка + действия снизу. Сейчас всё в одну строку, из-за чего имена серверов
   обрезаются (в коде уже есть подпорки `_kLatencySlotWidth = 40` и
   `_kStationNameMinWidth = 140` — после переверстки они не нужны, убрать).
5. Группы-подписки: `ExpansionTile` в стиле Atlas, без material-скруглений.

**Приёмка:**
- скриншот 360dp: заголовок «Stations & Sources» в одну-две строки нормальным текстом,
  ни одной буквы в столбик
- `flutter test test/features/station_row_test.dart` зелёный
- `grep -n "_kStationNameMinWidth" lib/features/servers/` → пусто (подпорка удалена)

---

## T3.4 — Настройки

**Приоритет:** P1. **Оценка:** 6 ч.
**Файл:** `lib/features/settings/settings_screen.dart` (1823 строки ✅ VERIFIED).

**Проблемы.**
- 1823 строки в одном файле; десятки переключателей без группировки по важности
- `settings_screen.dart:1388` ⚠️ SUBAGENT: `AutostartService.setEnabled()` вызывается **без
  проверки платформы** → `Process.runSync('reg', …)` на Android
- Windows-команды (`explorer`, `rundll32`, `powershell`) без гардов

**Шаги.**
1. Разбить на секции-файлы: `sections/connection_section.dart`, `tunnel_section.dart`,
   `dns_section.dart`, `appearance_section.dart`, `advanced_section.dart`,
   `platform_section.dart`, `about_section.dart`.
2. **Все платформенные пункты гейтить** на `AppPlatform.isDesktop` — не отключённые,
   а вообще отсутствующие на мобиле. Пункт, который виден и падает при нажатии, хуже
   отсутствующего.
3. Опасные настройки (kill switch, TUN, DNS) — с пояснением последствий, а не только
   переключатель.
4. Компоновки: narrow/phone — список; tablet/desktop — две колонки (навигация по секциям |
   содержимое).

**Приёмка:** на Android-скриншоте нет ни одного desktop-пункта; `grep -n "Process.run"
lib/features/settings/` → каждый вызов внутри `if (AppPlatform.isDesktop)`.

---

## T3.5 — Диалог добавления сервера

**Приоритет:** P1. **Оценка:** 4 ч.
**Файл:** `lib/features/servers/add_server_dialog.dart` (1510 строк ✅ VERIFIED).

Диалог на 1510 строк — четыре способа ввода (руками / из буфера / QR / файл) в одном классе.
На телефоне модальный диалог с формой почти всегда хуже полноэкранного листа.

**Шаги.**
1. Расслоить на `add_server/manual_form.dart`, `clipboard_import.dart`, `qr_import.dart`,
   `file_import.dart` + общий контроллер.
2. При narrow/phone — полноэкранный `Scaffold` вместо `Dialog`; при tablet/desktop — диалог
   с `maxWidth: 560`.
3. QR-импорт (`zxing_lib` + `image`) — проверить работоспособность на Android; на десктопе
   он читает из файла, на мобиле логично с камеры, но камеры в зависимостях нет. Если камеры
   нет — честно убрать пункт на мобиле, а не показывать неработающий.
4. Валидация с внятными ошибками под полем, не `SnackBar` поверх формы.

**Приёмка:** скриншоты обоих режимов; на 360dp форма не требует горизонтального скролла.

---

## T3.6 — Пакет средних экранов (3 шт., один исполнитель)

**Приоритет:** P1. **Оценка:** 6 ч на все три.

| Файл | Строк | Что делать |
|---|---|---|
| `features/provider_profile/provider_profile_screen.dart` | 698 | карточки провайдера, кнопки автоподключения — на narrow в колонку |
| `features/egresses/egresses_screen.dart` | 683 | список выходных узлов, та же схема, что станции |
| `features/groups/groups_screen.dart` | 654 | уже имеет `_twoColumnBreakpoint = 900` — перевести на `AtlasBreak`; **в файле есть хардкод русского текста** ✅ VERIFIED — вынести в l10n (T5.4) |

Общее: токены, `AtlasCard`/`AtlasEmptyState`, четыре компоновки, `Semantics`, golden-тесты.

**Приёмка:** для каждого — скриншот 360 и 1280, `flutter test` зелёный.
Существующий `test/features/groups_screen_test.dart` не должен сломаться.

---

## T3.7 — Пакет биллинга и аккаунта (3 шт., один исполнитель)

**Приоритет:** P1. **Оценка:** 5 ч.

| Файл | Строк | Особенность |
|---|---|---|
| `features/billing/billing_dialogs.dart` | 636 | на мобиле — полноэкранные листы |
| `features/billing/billing_screen.dart` | 578 | тарифы: на narrow карточки в колонку, цена крупно |
| `features/account/account_screen.dart` | 539 | `maxW = 720` (строка 90) — вынести в `AtlasLayout.readableMaxWidth` |

Отдельно: суммы и даты через `intl` с русской локалью (`intl` уже в зависимостях). Сейчас
формат, скорее всего, английский — проверить и исправить, это видно пользователю.

**Приёмка:** `test/features/account_screen_test.dart` и `test/billing_test.dart` зелёные;
скриншоты; суммы в формате «199 ₽», не «199.00 RUB».

---

## T3.8 — Пакет мелких экранов (6 шт., один исполнитель)

**Приоритет:** P2. **Оценка:** 6 ч.

`subscriptions_screen.dart` (445), `routing_screen.dart` (431), `logs_screen.dart` (384),
`connections_screen.dart` (366), `profiles_screen.dart` (361), `stats_screen.dart` (342).

Особые случаи:
- **`logs_screen.dart`** — консоль. Моношрифт обязателен, горизонтальный скролл для длинных
  строк допустим (это единственное место, где он уместен). Использовать
  `consoleError/Warning/Success/Muted/Text` — у них уже посчитан контраст на `bgInk`.
  Проверить `Process.run` на гарды платформы ⚠️ SUBAGENT.
- **`stats_screen.dart`** — `fl_chart`. На narrow графики часто нечитаемы: уменьшить число
  подписей осей, а не шрифт до 8pt.
- **`connections_screen.dart`** — таблица соединений. На мобиле таблица не работает:
  переделать в карточки.

**Приёмка:** скриншоты 360 и 1280 для каждого; `flutter analyze` → 0.

---

## T3.9 — Пакет остальных (2 шт.)

**Приоритет:** P2. **Оценка:** 3 ч.

`cores_screen.dart` (288), `speedtest_screen.dart` (261), `more_screen.dart` (202).
`more_screen.dart` координируется с T1.6 (мобильная навигация) — он и есть точка входа
в экраны, недостижимые из нижней навигации.

**Приёмка:** после этой задачи `grep -rn "EdgeInsets.all(24)" lib/features/ | wc -l` → **0**
и `grep -rhoE "fontSize: [0-9]" lib/features/ | wc -l` → **0**. Это финальная проверка
всей волны 3.
