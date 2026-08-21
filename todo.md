# Текущая блокирующая диагностика Android и Smart Groups

- [ ] Проверить логи `mosaic-bot`, Android daemon и sing-box на запрос scoped candidate feed, выбор кандидатов и probe без раскрытия URI или ключей.
- [ ] Сопоставить live manifest, обычную subscription link и daemon route inventory: Android должен видеть один direct virtual route плюс server-defined Smart Groups.
- [ ] Исправить разбор или нормализацию xHTTP transport, вызывающий `unknown transport type: xhttp` в Android runtime.
- [ ] Добавить regression-тесты: direct route не исчезает для Mosaic source, а xHTTP candidate не вызывает invalid_config.
- [ ] Собрать и опубликовать исправленный Android-клиент, затем подтвердить добавление direct route и успешный выбор маршрута на устройстве.
