MosaicVPN — Native GUI Client

MosaicVPN — легковесный VPN-клиент с нативным интерфейсом на Rust + Slint.
Потребление RAM: ~15 MB. Размер: ~13 MB.

Состав:
  mosaicvpn.exe  — основной исполняемый файл (GUI + API клиент)
  icon.ico       — иконка приложения

Требования:
  mosaicvpn daemon (mosaicd) должен быть запущен в системе.
  Демон создаёт файл блокировки (daemon.lock) с портом и токеном API.

Запуск:
  Просто запустите mosaicvpn.exe — он автоматически найдёт демон
  и подключится к его локальному API.

Версия: 0.1.0
Лицензия: MIT
GitHub: https://github.com/DangerousANEN/mosaicvpn
