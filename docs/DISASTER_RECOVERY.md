# Регламент аварийного восстановления и авторазвертывания (Disaster Recovery Playbook) — MosaicVPN

> **Версия документа**: 1.0  
> **Целевое время восстановления (RTO)**: ≤ 5 минут  
> **Допустимая потеря данных (RPO)**: ≤ 12 часов (бэкапы дважды в сутки: 03:00 и 15:00 UTC)  
> **Поддерживаемые ОС**: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Debian 12  

---

## 1. Архитектурная карта сервиса

Production-стек MosaicVPN разворачивается как единый комплекс:
1. **База данных PostgreSQL 15**: Контейнер `remnawave-db` (порт `127.0.0.1:6767`, volume `remnawave-db-data`).
2. **Кэш & Сокеты Valkey / Redis**: Контейнер `remnawave-redis` (unix domain socket `/var/run/valkey`).
3. **Remnawave Backend & Subscription Page**: Контейнеры `remnawave` (порт `3000`) и `remnawave-subscription-page` (порт `3010`).
4. **Реверс-прокси Nginx 1.24**: Контейнер `remnawave-nginx` (порты `80`, `443`, `8443`). Отдает статический лендинг, документацию, SEO-блог, SEO-панель управления и проксирует API в бота.
5. **Telegram Bot & Cabinet Daemon**: Сервис `mosaic-bot.service` (Python venv в `/opt/mosaic-bot`, порт `12223`).
6. **Система автобэкапов**: `mosaic-backup.timer` (снапшоты в `/var/backups/mosaic-db/`).

---

## 2. Сценарии аварий

### Сценарий A: Полный отказ или блокировка текущего сервера (Blackout / Migration)
*Если хостинг удалил VPS, диск вышел из строя или IP заблокирован:*

#### Шаг 1: Аренда нового сервера
Создайте чистый инстанс **Ubuntu 22.04 LTS** (или 24.04) у любого провайдера (любой регион: Нидерланды, Германия, Финляндия, США).  
Рекомендуемые параметры: 2 vCPU, 4GB RAM, 40GB NVMe.

#### Шаг 2: Клонирование репозитория на новый сервер
Подключитесь по SSH к новому серверу:
```bash
ssh root@<НОВЫЙ_IP>
```
Склонируйте репозиторий MosaicVPN:
```bash
git clone https://github.com/ANEN2k/mosaicvpn.git /opt/mosaicvpn-src
cd /opt/mosaicvpn-src
```

#### Шаг 3: Перенос последнего дампа базы данных
Скопируйте последний проверенный локальный бэкап с рабочего ПК на новый сервер:
```bash
# Выполняется на вашей локальной машине:
scp backups/mosaic_db_latest.sql.gz root@<НОВЫЙ_IP>:/root/mosaic_db_latest.sql.gz
```

#### Шаг 4: Запуск 1-Click Bootstrap инсталлятора
На новом сервере выполните одну команду:
```bash
cd /opt/mosaicvpn-src/deploy
chmod +x bootstrap_server.sh
./bootstrap_server.sh --restore /root/mosaic_db_latest.sql.gz
```
Скрипт автоматически:
- Установит Docker CE, Docker Compose v2, Python3, UFW, Certbot, Fail2ban.
- Настроит UFW (разрешит 22, 80, 443, 8443; закроет БД снаружи).
- Развернет стек `/opt/remnawave` и запустит контейнеры.
- Накатит дамп базы данных через `/opt/mosaicvpn/scripts/backup/restore_db.sh`.
- Настроит виртуальное окружение бота `/opt/mosaic-bot/venv`.
- Включит таймер бэкапов `mosaic-backup.timer`.
- Запустит `mosaic-bot.service`.

#### Шаг 5: Перенаправление DNS в Cloudflare
В панели управления DNS Cloudflare измените A-записи на новый IP:
- `sub.zxc1x1.ru` → `<НОВЫЙ_IP>` (Proxy: DNS Only или Proxied)
- `panel.zxc1x1.ru` → `<НОВЫЙ_IP>`

#### Шаг 6: Сертификаты SSL (Let's Encrypt)
Если сертификаты выпускаются заново:
```bash
certbot certonly --standalone -d sub.zxc1x1.ru -d panel.zxc1x1.ru --agree-tos -m anen.online@gmail.com
```
И скопируйте их в смонтированную директорию:
```bash
mkdir -p /opt/remnawave/nginx/ssl/sub.zxc1x1.ru
cp /etc/letsencrypt/live/sub.zxc1x1.ru/fullchain.pem /opt/remnawave/nginx/ssl/sub.zxc1x1.ru/
cp /etc/letsencrypt/live/sub.zxc1x1.ru/privkey.pem /opt/remnawave/nginx/ssl/sub.zxc1x1.ru/
docker restart remnawave-nginx
```

---

### Сценарий B: Повреждение данных или случайное удаление таблиц

Если сервер работает, но база данных была повреждена или требуется откат:
```bash
# 1. Посмотреть доступные бэкапы:
ls -la /var/backups/mosaic-db/

# 2. Запустить безопасное восстановление из последнего снапшота:
/opt/mosaicvpn/scripts/backup/restore_db.sh /var/backups/mosaic-db/latest.sql.gz

# 3. Перезапустить зависимые сервисы:
systemctl restart mosaic-bot
docker restart remnawave
```

---

## 3. Регламент проверки после восстановления (Health Check)

Выполните команду на локальном ПК или сервере:
```bash
# 1. Проверка доступности SEO блога и документации:
curl -sI https://sub.zxc1x1.ru/blog/ | grep -E 'HTTP|Server'
curl -sI https://sub.zxc1x1.ru/seo.html | grep -E 'HTTP|Server'

# 2. Проверка целостности SEO-панели через агентский скрипт:
python scripts/seo_analyzer.py --remote

# 3. Проверка ответа Telegram-бота:
curl -sI https://sub.zxc1x1.ru/api/cabinet/health || true

# 4. Проверка статуса таймера бэкапов:
systemctl status mosaic-backup.timer
```

---

## 4. Контроль конфиденциальности
- В Git-репозиторий категорически запрещено коммитить реальные пароли и дампы `.sql.gz`.
- Все секреты задаются на сервере в `/opt/remnawave/.env` и `/etc/mosaic-bot.env` (права `chmod 600`).
- Шаблоны переменных хранятся в репозитории как `deploy/env.example`.
