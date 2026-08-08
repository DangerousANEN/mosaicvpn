Кроссплатформенный релиз: клиент MosaicBox теперь собирается под Windows, Linux и Android из одной кодовой базы.

## Загрузки

| Платформа | Файл | Размер |
|---|---|---|
| Windows x64 | `MosaicVPN-windows-x64.zip` | 40 МБ |
| Linux x86_64 | `MosaicVPN-linux-x86_64.tar.gz` | 37 МБ |
| Android (arm64/arm/x64) | `MosaicBox-android.apk` | 66 МБ |

Каждый десктопный архив содержит GUI, демон `mosaicd`, CLI `mosaic` и движок sing-box 1.13.14 — распаковал и запустил, ничего доустанавливать не нужно.

## Установка

**Windows** — распаковать архив и запустить `mosaic_vpn.exe`.

**Linux** — распаковать и запустить бинарник:
```bash
tar -xzf MosaicVPN-linux-x86_64.tar.gz
cd MosaicVPN
./mosaic_vpn
```

**Android** — установить APK (потребуется разрешить установку из неизвестных источников). Минимальная версия — Android 7.0 (API 24).

## Что изменилось

### Клиент
- Android-проект собран заново — раньше gradle-файлы отсутствовали, сборка под Android была невозможна
- Плагины `window_manager` и `system_tray` теперь вызываются только на десктопе. Прежняя проверка `!kIsWeb` пропускала мобильные платформы, и приложение падало на старте
- Обращения к `Platform.environment` закрыты проверкой платформы — на вебе и мобильных они бросали `UnsupportedError` на всех экранах кроме дашборда
- `compileSdk` поднят до 36 для приложения и библиотек: `file_picker` до сих пор объявляет 34, и Flutter Gradle plugin отклонял сборку
- `intl` обновлён до ^0.20.2 под требования `flutter_localizations`
- Заменены устаревшие API: `Matrix4.scaleByDouble`, `Switch.activeThumbColor`, `DropdownButtonFormField.initialValue`, `ReorderableListView.onReorderItem`
- `dart analyze` — 0 замечаний

### Демон
- Имя mutex для single-instance на Windows теперь выводится из пути lock-файла, а не задано глобальной константой. Раньше два экземпляра с разными `--data-dir` ложно считали друг друга дубликатом. Добавлен регрессионный тест на изоляцию

### Сайт
- Старая сборка панели Remnawave заменена лендингом MosaicVPN: битые ссылки на ассеты и неподставленные EJS-плейсхолдеры убраны, добавлен раздел загрузок по платформам

### Сборка
- Добавлен `scripts/package_release.sh` — собирает архивы под все платформы
- Движок sing-box кладётся рядом с демоном (`LocateSingBox()` ищет его именно там). Отсутствие движка теперь останавливает упаковку, а не даёт молча неполный архив

## Проверено

- `go vet` — чисто, `go test ./...` — все пакеты проходят
- `dart analyze` — 0 замечаний
- Windows и Linux GUI собраны из текущего кода, Linux-движок проверен запуском (`sing-box version 1.13.14`)
- APK: `ru.mosaicvpn.mosaic_vpn`, versionName 0.2.0, minSdk 24, targetSdk 36
