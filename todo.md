# Текущая блокирующая диагностика Android и Smart Groups

- [x] Проверить логи `mosaic-bot`, Android daemon и sing-box на запрос scoped candidate feed, выбор кандидатов и probe без раскрытия URI или ключей.
- [x] Сопоставить live manifest, обычную subscription link и daemon route inventory: Android должен видеть один direct virtual route плюс server-defined Smart Groups.
- [x] Исправить разбор или нормализацию xHTTP transport, вызывающий `unknown transport type: xhttp` в Android runtime.
- [x] Добавить regression-тесты: direct route не исчезает для Mosaic source, а xHTTP candidate не вызывает invalid_config.
- [ ] Установить v0.3.30 на физический Android и подтвердить отображение Mosaic Direct рядом со Smart Groups, затем выполнить одно успешное подключение direct и одной Smart Group.
