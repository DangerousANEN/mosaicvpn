# Волна 1 — Дизайн-система (фундамент)

> **Блокирует волны 2 и 3.** Без неё каждый экран будет переверстан в свою сторону.
> Задачи T1.1–T1.6. T1.1 и T1.2 идут строго последовательно, дальше можно параллелить.

---

## Общий context-блок для UI-задач (волны 1–3)

Вставлять в `context` КАЖДОЙ задачи волн 1–3, целиком:

```
Проект: MosaicVPN, Flutter-клиент MosaicBox.
Путь: C:\Users\ANEN\mosaicvpn\flutter\
Flutter 3.44.6, Dart, Riverpod (flutter_riverpod ^2.6.1), Dio, fl_chart, flutter_svg.
Хост Windows, terminal() = bash (MSYS), НЕ PowerShell, POSIX-синтаксис.
66 Dart-файлов, 24358 строк.

ДИЗАЙН-СИСТЕМА ATLAS — КАНОН, менять нельзя:
Палитра (lib/core/theme/atlas_theme.dart:12-46, НЕ ТРОГАТЬ значения):
  бумага #F4EFE6, пергамент #EDE5D6, приподнятый #E4DAC6, чернила #2B2620,
  терракота #B85C38 (акцент), оливковый #5B7A3A (успех), янтарный #C47830 (warning),
  ржавый #A8442A (ошибка), стальной #4B6B7A (инфо),
  границы #C4B89E / #D4C9B0 / #5C4E3A,
  текст #2B2620 / #6B5D4A / #9A8B72.
Тёмная тема: darkBg* / darkText* в том же файле.

Визуальный язык — печатный картографический атлас:
  серифные заголовки; моноширинные подписи-легенды КАПСЛОКОМ с letter-spacing;
  тонкие линии-разделители 1px; номера разделов («Раздел II · …»);
  подписи к рисункам («Figure 1 · …»); радиусы 4/8/12 максимум.

ЗАПРЕЩЕНО:
  material-градиенты; радиусы > 12px; elevation-тени в стиле Material 3;
  синий как акцент; эмодзи вместо иконок в элементах управления;
  менять значения цветов из палитры; добавлять новые цвета вне atlas_theme.dart.

ANTI-SIMPLIFICATION правила (обязательны):
- НЕ писать заглушки 'TODO: implement' — только полная реализация
- НЕ пропускать секции/поля/props — всё из спецификации
- НЕ упрощать анимации и переходы — реализовать как описано
- НЕ хардкодить цвета: только через ThemeColors.of(context) — есть guard-тест,
  он ВАЛИТ сборку на Color(0x…) и Colors.white в lib/features/
- НЕ хардкодить размеры шрифта, отступы и брейкпоинты — только токены
- НЕ ломать существующие тесты в flutter/test/ (их 11 файлов)
- НЕ трогать бизнес-логику: провайдеры, DaemonApi, модели — только вёрстка
- НЕ сообщать об успехе без вывода flutter analyze и flutter test

ОБЯЗАТЕЛЬНО в отчёте:
1. Полный вывод `flutter analyze` (должно быть 0 issues)
2. Полный вывод `flutter test`
3. Список изменённых файлов с числом строк (`git status --short` + `wc -l`)
4. Для вёрстки — скриншот или явное указание, что визуально не проверялось
Отчёт на русском.
```

---

## T1.1 — Подключить собственные шрифты (корень проблемы)

**Приоритет:** P0 для вёрстки. **Блокирует:** T1.2 и всё дальше. **Оценка:** 3 ч.

**Проблема** ✅ VERIFIED:
```
$ grep -A12 "fonts:" flutter/pubspec.yaml   → секции fonts НЕТ
$ ls -la flutter/assets/fonts/              → каталог ПУСТОЙ
# atlas_theme.dart:54-56
serifFamily = 'serif'; monoFamily = 'monospace'; sansFamily = 'sans-serif';
```
Три системных алиаса. На Windows `serif` → Times New Roman, на Linux → DejaVu Serif,
на Android → Noto Serif и по-разному на разных прошивках. Один экран выглядит тремя
разными продуктами. **Это первая причина, почему Android-скриншот смотрится дешевле
linux-скриншота** — ещё до всех проблем с раскладкой.

**Выбор шрифтов.** Все три обязательно с полной кириллицей — продукт русскоязычный,
и «серифная латиница + системная кириллица» даст рваный текст.

| Роль | Шрифт | Лицензия | Начертания | Почему |
|---|---|---|---|---|
| serif (заголовки) | **Source Serif 4** | OFL | Regular 400, SemiBold 600 | гуманистическая антиква, есть кириллица, «печатный» тон без вычурности |
| sans (интерфейс) | **Inter** | OFL | Regular 400, Medium 500, SemiBold 600 | высокая читаемость в мелких кеглях, полная кириллица; уже используется на сайте — единый тон продукта |
| mono (легенды, консоль) | **JetBrains Mono** | OFL | Regular 400, Medium 500 | кириллица есть, различимые 0/O и 1/l/I — важно для логов и токенов |

Альтернатива serif, если Source Serif покажется тяжёлым в мелком кегле: **Literata** (OFL,
кириллица есть). Решение — за исполнителем, но зафиксировать в отчёте с обоснованием.

**Шаги.**

1. Скачать статические `.ttf` (НЕ variable — Flutter на Android капризен к variable-осям)
   в `flutter/assets/fonts/`. Только нужные начертания, не весь набор: лишний вес попадёт в APK.
   Ожидаемо ~8 файлов, суммарно ≤ 1.5 МБ.
2. `pubspec.yaml` — добавить секцию `fonts:` со всеми тремя семействами и начертаниями,
   с корректными `weight`.
3. `atlas_theme.dart:54-56` — заменить алиасы:
```dart
static const String serifFamily = 'SourceSerif4';
static const String sansFamily  = 'Inter';
static const String monoFamily  = 'JetBrainsMono';
```
4. Прогнать `flutter pub get`, затем `flutter analyze`.
5. **Проверка кириллицы обязательна** — иначе половина текста уйдёт в квадраты: тест
   `test/fonts_test.dart`, который рендерит строку «Подключение · Станции · Задержка 42 мс»
   каждым из трёх семейств и утверждает отсутствие исключений.
6. Замерить прирост размера APK: `flutter build apk --release --split-per-abi` до и после,
   числа — в отчёт. Если прирост > 3 МБ — сократить начертания.

**Приёмка:**
- `grep -n "serifFamily\|sansFamily\|monoFamily" lib/core/theme/atlas_theme.dart` показывает
  имена семейств, не системные алиасы
- `flutter test test/fonts_test.dart` зелёный
- в отчёте — прирост размера APK в МБ

**НЕ ДЕЛАТЬ:** не подключать `google_fonts` пакет (тянет шрифты по сети в рантайме — VPN-клиент
не должен зависеть от сети для отрисовки текста и не должен звонить на Google-CDN).

---

## T1.2 — Токены размеров, отступов, типографики

**Приоритет:** P0 для вёрстки. **Зависит от:** T1.1. **Блокирует:** T1.3+, всю волну 3.
**Оценка:** 4 ч.

**Проблема** ✅ VERIFIED: 334 хардкода `fontSize` в 15 различных значениях
(82×12, 59×11, 48×13, 34×10, 29×14, 21×16, 18×18, 14×9, 9×15, 6×8, 4×24, 3×22, 3×20, 2×32, 1×28)
и сотни `SizedBox` с литералами (72× width:8, 57× height:12, 48× height:16, 40× height:8…).
15 размеров шрифта — это не шкала, это разброс.

**Шаги.**

1. Создать `lib/core/theme/atlas_tokens.dart`:

```dart
/// Единственный источник истины для размеров, отступов и типографики Atlas.
/// Цвета живут в atlas_theme.dart — здесь их нет намеренно.
class AtlasSpace {
  const AtlasSpace._();
  /// Сетка кратна 4: любой отступ вне этой шкалы — ошибка вёрстки.
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AtlasType {
  const AtlasType._();
  // Шкала кегля: 8 ступеней вместо нынешних 15 значений.
  static const double caption   = 10;  // подписи под элементами
  static const double legend    = 11;  // моноширинные легенды капслоком
  static const double body      = 12;  // основной текст интерфейса
  static const double bodyLarge = 13;
  static const double subtitle  = 14;
  static const double title     = 16;
  static const double heading   = 18;  // SectionHeader
  static const double display   = 28;  // крупный статус подключения
}
```

2. Роли текста как готовые `TextStyle` — чтобы экран не собирал стиль вручную:
```dart
class AtlasTextStyles {
  static TextStyle heading(BuildContext ctx) => TextStyle(
        fontFamily: AtlasTheme.serifFamily,
        fontSize: AtlasType.heading,
        fontWeight: FontWeight.w600,
        color: ThemeColors.of(ctx).textPrimary,
      );
  static TextStyle legend(BuildContext ctx) => TextStyle(
        fontFamily: AtlasTheme.monoFamily,
        fontSize: AtlasType.legend,
        letterSpacing: 0.1 * AtlasType.legend,
        color: ThemeColors.of(ctx).textMuted,
      );
  // + body, bodyLarge, subtitle, title, caption, display, mono
}
```

3. Адаптивный отступ экрана — вместо 16 хардкодов `EdgeInsets.all(24)`:
```dart
class AtlasLayout {
  static EdgeInsets screenPadding(BuildContext ctx) {
    final w = MediaQuery.of(ctx).size.width;
    if (w < AtlasBreak.phone) return const EdgeInsets.all(AtlasSpace.md);
    if (w < AtlasBreak.tablet) return const EdgeInsets.all(AtlasSpace.lg);
    return const EdgeInsets.all(AtlasSpace.xl);
  }
}
```

4. **Не переписывать все 334 вхождения в этой задаче** — только создать токены и применить
   в `lib/shared/widgets/` (там 4 файла). Экраны переводятся в волне 3, по одному, чтобы
   диффы читались.

**Приёмка:**
- файл `atlas_tokens.dart` существует, `flutter analyze` → 0 issues
- `grep -rhoE "fontSize: [0-9]" lib/shared/` → **0 вхождений**
- существующие 11 тестов не сломались

---

## T1.3 — Единые брейкпоинты

**Приоритет:** P1. **Зависит от:** T1.2. **Оценка:** 2 ч.

**Проблема** ✅ VERIFIED — пять брейкпоинтов в пяти файлах:
```
app_shell.dart:560                  maxWidth < 480
app_shell.dart (build)              shortestSide > 600
dashboard_screen.dart:200           w < 600
account_screen.dart:90              maxWidth > 720
groups_screen.dart:25               _twoColumnBreakpoint = 900
atlas_widgets.dart:97               maxWidth < 420
```
Каждый экран решает про мобильность сам → состояния, где шелл считает экран телефоном,
а дашборд внутри — планшетом.

**Шаги.**

1. В `atlas_tokens.dart` добавить:
```dart
class AtlasBreak {
  const AtlasBreak._();
  /// Узкий телефон (320–400dp): одна колонка, самая плотная компоновка.
  static const double narrow = 400;
  /// Телефон (400–600dp): одна колонка, обычная плотность.
  static const double phone  = 600;
  /// Планшет (600–900dp): две колонки, боковая навигация.
  static const double tablet = 900;
  /// Десктоп (900+): три колонки, полный сайдбар.
  static const double desktop = 900;
}

enum AtlasFormFactor { narrow, phone, tablet, desktop }

AtlasFormFactor atlasFormFactor(BuildContext ctx) { … }
```
2. **Важно:** шелл использует `shortestSide` (чтобы телефон в лендскейпе не получал
   десктопный сайдбар — это уже исправлено в рабочей копии), экраны используют
   `constraints.maxWidth` (они меряют свою колонку, а не устройство). Разница намеренная —
   зафиксировать в докстринге, иначе следующий разработчик «унифицирует» и сломает.
3. Заменить все 6 мест на токены. `account_screen.dart:90` (`maxW = 720`) — это
   ограничение ширины контента, а не брейкпоинт: вынести как `AtlasLayout.readableMaxWidth`.

**Приёмка:** `grep -rnE "(maxWidth|shortestSide|size\.width) *[<>] *[0-9]{3}" lib/` →
только внутри `atlas_tokens.dart`.

---

## T1.4 — Расширить guard-тест на размеры и брейкпоинты

**Приоритет:** P1. **Зависит от:** T1.2, T1.3. **Оценка:** 2 ч.

**Почему это важнее, чем кажется:** `test/theme_guard_test.dart` уже существует и запрещает
хардкод цветов, валя сборку на `Color(0x…)` и `Colors.white` в feature-экранах ✅ VERIFIED.
Именно поэтому цвета — единственная часть дизайн-системы, которая не расползлась.
Тот же приём нужно применить к размерам, иначе через месяц вернутся те же 15 кеглей.

**Шаги.**

1. Расширить `theme_guard_test.dart` (или создать `tokens_guard_test.dart`) правилами:
   - `fontSize: <литерал>` в `lib/features/` и `lib/shared/` → fail
   - `EdgeInsets.all(<литерал>)` где литерал не из шкалы 4/8/12/16/24/32 → fail
   - `SizedBox(width|height: <литерал>)` вне шкалы → fail
   - трёхзначные литералы в сравнениях ширины вне `atlas_tokens.dart` → fail
2. Сообщение об ошибке должно **учить**, а не просто ругаться:
```
lib/features/servers/servers_screen.dart:412
  найдено: fontSize: 13
  используйте: AtlasType.bodyLarge (13) из core/theme/atlas_tokens.dart
  почему: 15 разных кеглей в проекте = визуальный разброс; шкала — 8 ступеней
```
3. Whitelist для честных исключений — с обязательным комментарием-обоснованием в коде,
   иначе whitelist станет свалкой.

**Приёмка:** тест падает на намеренно внесённом `fontSize: 17`, проходит после замены на токен.
Оба прогона — в отчёт.

---

## T1.5 — Библиотека компонентов Atlas

**Приоритет:** P1. **Зависит от:** T1.2. **Блокирует:** волну 3. **Оценка:** 6 ч.

**Проблема:** `shared/widgets/` содержит `SectionHeader`, `StatTile`, `StatusDot`,
`LatencyBadge` — но 16 экранов собирают карточки, пустые состояния, панели и тулбары
каждый по-своему. Отсюда «Add Source» одной формы на одном экране и другой на соседнем.

**Создать в `lib/shared/widgets/atlas/`:**

| Компонент | Назначение | Обязательное адаптивное поведение |
|---|---|---|
| `AtlasCard` | карточка-пергамент с рамкой и опциональным заголовком | padding по form factor |
| `AtlasPanel` | панель дашборда с моно-легендой в шапке | на narrow — заголовок над содержимым, не в строку |
| `AtlasEmptyState` | пустое состояние: иконка, заголовок, текст, кнопка | кнопка на всю ширину при narrow |
| `AtlasToolbar` | ряд действий | `Wrap` вместо `Row` при narrow; при > 3 действий — «ещё» в меню |
| `AtlasMetric` | метрика: подпись + значение + единица | `FittedBox(scaleDown)` для значения — иначе «DISCONNECTED» ломается в столбик |
| `AtlasListRow` | строка списка сервера/подписки | на narrow — двухстрочная компоновка |
| `AtlasSectionTitle` | номер раздела + заголовок + подзаголовок | уже есть в `SectionHeader`, перенести и обобщить |
| `AtlasFigureCaption` | «Figure N · …» под графикой | скрывается при height < 200 |

**Требования к каждому:**
1. Никаких литералов — только токены.
2. `Semantics`-обёртка с осмысленным `label` — сейчас в проекте **ноль** `Semantics`
   ✅ VERIFIED, скринридер видит безымянные прямоугольники.
3. Golden-тест на 320 / 360 / 768 dp.
4. Докстринг: когда применять и когда НЕ применять.

**Приёмка:** `flutter test test/shared/atlas/` — все зелёные; 8 компонентов существуют;
в каждом есть `Semantics`.

---

## T1.6 — Мобильная навигация: доступность всех экранов

**Приоритет:** P1. **Оценка:** 3 ч.

**Проблема** ⚠️ SUBAGENT + ✅ VERIFIED частично: на широком экране сайдбар показывает
`visibleIndices = [0, 1, 3, 5, 6, 11, 14]` (или все 15 в advanced-режиме), а на мобильном
`BottomNavigationBar` отдаёт только `_mainDestinations`. Часть экранов на телефоне
недостижима. Есть `more_screen.dart` (202 строки) — похоже, задумывался как решение, но
нужно проверить, что он реально покрывает разницу.

**Шаги.**

1. Составить таблицу: все 15 destinations × достижимость на телефоне (напрямую / через More /
   недостижим). Таблицу — в отчёт.
2. Закрыть дыры через `more_screen.dart`.
3. `BottomNavigationBar` с 5+ элементами на 320dp обрезает подписи — проверить и при
   необходимости оставить 4 основных + «Ещё».
4. Тест `test/navigation_reachability_test.dart`: для каждого экрана из списка — программно
   дойти до него на 360dp. Это единственный способ не потерять экран при следующем рефакторинге.

**Приёмка:** тест доказывает достижимость всех 15 экранов на 360dp.
