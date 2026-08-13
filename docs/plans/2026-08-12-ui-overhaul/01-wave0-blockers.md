# Волна 0 — Блокеры сервиса

> Идёт параллельно всем остальным волнам. Не ждёт вёрстки.
> Задачи T0.1–T0.7. Каждая — отдельный субагент, кроме T0.3/T0.4, где нужно решение владельца.

---

## Общий context-блок для задач волны 0

Вставлять в `context` каждой задачи:

```
Проект: MosaicVPN. Хост — Windows, terminal() = bash (MSYS), НЕ PowerShell.
POSIX-синтаксис. Пути: C:\Users\ANEN\mosaicvpn\...
VPS: ssh -i ~/.ssh/id_ed25519_vitaly -o ConnectTimeout=15 root@5.175.188.152
nginx работает ВНУТРИ docker-контейнера remnawave-nginx, конфиг /opt/remnawave/nginx.conf,
proxy_pass на бота идёт на docker-gateway http://172.18.0.1:12223
Статика лендинга: /etc/letsencrypt/landing/
Бот: systemd unit mosaic-bot.service, /opt/mosaic-bot/bot.py, Restart=always

ANTI-SIMPLIFICATION правила (обязательны):
- НЕ писать заглушки 'TODO: implement' — только полная реализация
- НЕ заменять реальные команды на placeholder '[command]' — точные команды
- НЕ пропускать шаги — всё из спецификации
- НЕ сообщать об успехе без вывода команды проверки
- НЕ печатать значения секретов — только имена переменных, значения как [REDACTED]

ОБЯЗАТЕЛЬНО в отчёте: для каждого шага — точная команда и её фактический вывод.
Отчёт на русском.
```

---

## T0.1 — Освободить диск VPS и поставить лимиты навсегда

**Приоритет:** P0. **Риск:** высокий (боевой сервер). **Оценка:** 1 ч.

**Проблема** ✅ VERIFIED: `df -h /` → 21G/24G, 88%, свободно 3.0 ГБ.
`/var/log/journal` = 2.3 ГБ при пустом `/etc/systemd/journald.conf` (только строка `[Journal]`,
ни одного лимита). При заполнении диска встанет Postgres в `remnawave-db` → умрут все подписки.

**Шаги.**

1. Снимок «до» — вставить в отчёт:
```bash
ssh ... 'df -h /; du -sh /var/log/journal; du -sh /var/log/* | sort -rh | head -8; docker system df'
```

2. Обрезать журнал:
```bash
ssh ... 'journalctl --vacuum-size=300M'
```
Ожидаемо: `Vacuuming done, freed ~2.0G`.

3. Зафиксировать лимиты (иначе вернётся через месяц):
```bash
ssh ... 'printf "SystemMaxUse=300M\nSystemMaxFileSize=50M\nMaxRetentionSec=14day\n" >> /etc/systemd/journald.conf && systemctl restart systemd-journald && systemctl is-active systemd-journald'
```

4. Ротация rsyslog (`syslog.1` = 193 МБ):
```bash
ssh ... 'grep -n "rotate" /etc/logrotate.d/rsyslog'
ssh ... 'sed -i "s/rotate [0-9]\+/rotate 3/g" /etc/logrotate.d/rsyslog && logrotate -f /etc/logrotate.d/rsyslog'
```

5. Docker: 5 orphaned volumes (~251 МБ ⚠️ SUBAGENT) + старые образы.
```bash
ssh ... 'docker volume ls -qf dangling=true'      # СНАЧАЛА показать список
ssh ... 'docker volume prune -f; docker image prune -af --filter until=168h; docker system df'
```

6. Ротация логов cron-скриптов — их сейчас нет в logrotate:
`/var/log/singbox_watchdog.log`, `/var/log/selector_v2.log`, `/root/autonomous_cron.log`.
Создать `/etc/logrotate.d/mosaic-cron`:
```
/var/log/singbox_watchdog.log /var/log/selector_v2.log /root/autonomous_cron.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
```
Проверить: `logrotate -d /etc/logrotate.d/mosaic-cron` (dry-run, без ошибок).

**НЕ ДЕЛАТЬ без отдельного подтверждения владельца:**
- не удалять `/opt/flutter` (1.8 ГБ ⚠️ SUBAGENT) — только доложить размер и что там
- не трогать DePIN-фарм (Grass/Wynd ⚠️ SUBAGENT)
- не удалять `/opt/remnawave/backups`
- не перезапускать контейнеры Remnawave

**Приёмка:** `df -h /` показывает **≤ 70%**. Если после всех шагов больше — не «почти
получилось», а найти причину: `du -x -d1 / | sort -rh | head -15` и доложить.

---

## T0.2 — Оффсайт-бэкап БД + проверка восстановимости

**Приоритет:** P0. **Оценка:** 1 ч.

**Проблема** ✅ VERIFIED: `/opt/remnawave/backups` = 15 МБ, ежечасно, 30 дней — **на том же
диске**, который на 88% полон. Умрёт диск — умрут и данные, и их копии.
Хорошая новость ⚠️ SUBAGENT: дампы валидны (`pg_restore --list` → 228 TOC entries, CUSTOM).

**Шаги.**

1. Создать локальный каталог: `C:\Users\ANEN\mosaicvpn-backups\` (вне репозитория — там
   персональные данные, они не должны попасть в git).
2. Скрипт `C:\Users\ANEN\mosaicvpn\scripts\pull_backup.sh`: тянет самый свежий дамп через
   `scp`, проверяет `pg_restore --list` локально (если есть в MSYS — иначе только размер и
   контрольную сумму), хранит 14 копий, удаляет старые.
3. Прогнать вручную, вставить вывод в отчёт.
4. Оформить ежедневный запуск на локальной машине через `cronjob`-инструмент Hermes
   (`schedule='0 4 * * *'`, `no_agent=True`, тихий при успехе).

**Проверка восстановимости — обязательна, иначе бэкап это ритуал:**
```bash
pg_restore --list <локальный_дамп> | head -20
```
Должен показать таблицы, а не ошибку формата.

**Запрещено:** заливать дампы в сторонние облака/сервисы — персональные данные
пользователей. Только локальная машина владельца.

---

## T0.3 — Kill Switch: решение владельца, затем реализация

**Приоритет:** P0 (обман пользователя в security-функции).

**Проблема** ✅ VERIFIED:
```
$ grep -rn "internal/killswitch" --include=*.go . | grep -v "^./internal/killswitch/"
>>> НИ ОДНОГО ИМПОРТА ВНЕ ПАКЕТА <<<
```
Пакет с полноценным WFP-кодом и своим тестом не вызывается ниоткуда. UI пишет
«Kill switch is armed». Трафик утекает при обрыве.
Дополнительно ⚠️ SUBAGENT: WFP-сессия `DYNAMIC` удаляется ОС при выходе → **fail-OPEN
при крэше демона**. На Linux `noop.go` возвращает успех вместо «не поддерживается» — то есть
линуксовые пользователи тоже видят фиктивную защиту.

### Вариант A — убрать из UI (1 ч, делать сразу если B не начинается сегодня)

- `flutter/lib/app/app_shell.dart` — удалить `_KillSwitchToggle` из `_QuickStatusBar`
- `flutter/lib/features/dashboard/dashboard_screen.dart` — убрать «Kill switch is armed»
  из текста notice-блока
- `flutter/lib/features/security/` — переключатель либо убрать, либо явно подписать
  «в разработке»
- **Приёмка:** `grep -rin "kill.?switch" flutter/lib/` не находит ни одного утверждения,
  что защита активна.

### Вариант B — подключить по-настоящему (2–3 дня)

1. Вызывать `killswitch.Enable()` при переходе в `connected` и `Disable()` при
   `disconnected` — точка в `internal/state`.
2. Fail-CLOSED: заменить `DYNAMIC` WFP-сессию на persistent + гарантированная очистка
   при штатном выходе и sublayer-cleanup при старте (снять правила прошлого падения).
3. Linux: `noop.go` должен возвращать `ErrNotSupported`, а UI — честно показывать
   «недоступно на этой платформе», не «armed».
4. Тесты: `killswitch_test.go` расширить на сценарий «демон убит -9 → правила сняты».
5. Ручная проверка на Windows: подключиться, `taskkill /F` демона, убедиться, что
   трафик НЕ идёт (`curl` до внешнего IP должен падать).

**Оставлять как есть нельзя ни в каком варианте.**

---

## T0.4 — Android APK: снять с сайта или починить

**Приоритет:** P0. Решение владельца.

**Проблема** ✅ VERIFIED: в `AndroidManifest.xml` только `INTERNET`,
`ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`. Нет `BIND_VPN_SERVICE`,
нет `<service>`, нет `VpnService`. Нативного кода — только `MainActivity.kt`.
Хуже ⚠️ SUBAGENT: `daemon_launcher.dart:68` вызывает `Process.start` без Android-гарда,
падает молча, клиент сваливается в `MockDaemonApi` → **UI показывает «Connected» при нулевом
туннеле**.

Сайт при этом пишет ✅ VERIFIED (`site/index.html:280`): «Тот же интерфейс и подписки, что и
на десктопе, адаптированные под сенсорный ввод». Ни одно из трёх утверждений не выполняется.

### Вариант A — снять с сайта (30 мин, делать сегодня)

1. `site/index.html:273-291` — карточку Android заменить: убрать `<a class="dl-btn" href=…apk>`,
   поставить бейдж «В разработке», текст без обещаний.
2. Задеплоить: `scp site/index.html root@…:/etc/letsencrypt/landing/index.html`
3. Проверить: `curl -s https://sub.zxc1x1.ru/ | grep -c "\.apk"` → **0**
4. GitHub Release v0.3.0 — в описании пометить APK как нерабочий (`gh release edit`).

### Вариант B — реальная реализация: см. `05-wave4-platform.md`, задача T4.1

---

## T0.5 — Убрать внутреннюю записку с публичной оферты

**Приоритет:** P0. **Оценка:** 15 мин.

**Проблема** ✅ VERIFIED:
```
$ curl -s https://sub.zxc1x1.ru/offer.html | grep -c "notice-banner"   → 3
```
На живой публичной оферте висит служебный текст: «**Юридическое предупреждение для
проверяющего / владельца:** … Перед приёмом платежей рекомендуется правовая проверка
документа». Это заметка для владельца, а видит её каждый посетитель и модератор Lava —
и она буквально сообщает, что документ юридически не проверен.

**Шаги.**
1. Удалить блок `site/offer.html:200-206` (`<div class="notice-banner">…</div>`).
2. Проверить остальные 8 страниц на такие же служебные блоки:
   `grep -l "notice-banner\|для проверяющего\|для владельца" site/*.html`
3. Задеплоить, проверить: `curl -s https://sub.zxc1x1.ru/offer.html | grep -c "предупреждение"` → **0**

**Не трогать:** реквизиты в разделе 9 — они настоящие ✅ VERIFIED
(`Липский Никита Евгеньевич`, ИНН `545113651604`, НПД). **Ничего не выдумывать.**

---

## T0.6 — Идемпотентность зачисления подписки

**Приоритет:** P0. **Оценка:** 2 ч.

**Проблема** ✅ VERIFIED:
```python
# bot/bot.py:698
cursor.execute("UPDATE invoices SET status = ? WHERE invoice_id = ?", (status, invoice_id))
```
Нет `AND status='pending'`. `Restart=always` + поток поллинга → два прохода могут дважды
вызвать `api_extend_user` по одному инвойсу.
Аналогично ⚠️ SUBAGENT в Go: Lava-вебхук без идемпотентности, YooKassa-вебхук без проверки
IP и HMAC (`// TODO` в коде).

**Шаги.**

1. `bot/bot.py:695-701` — переписать:
```python
def update_invoice_status(invoice_id, status, expect='pending'):
    """Атомарный переход статуса. Возвращает True, только если ЭТОТ вызов его изменил."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "UPDATE invoices SET status = ? WHERE invoice_id = ? AND status = ?",
        (status, invoice_id, expect),
    )
    changed = cursor.rowcount == 1
    conn.commit()
    conn.close()
    return changed
```
2. В `polling_invoices_thread` (строка ~846) начислять **только** при `changed is True`:
   сначала перевести статус, потом продлевать. Не наоборот — иначе краш между вызовами
   даёт двойное начисление.
3. Тест `bot/test_payment_idempotency.py`: два последовательных вызова по одному
   `invoice_id` → второй возвращает `False`, `api_extend_user` вызван ровно один раз (mock).
4. Прогнать: `python -m pytest bot/test_payment_idempotency.py -v` → вывод в отчёт.

**Приёмка:** тест зелёный, в нём явно проверено, что второй вызов НЕ начисляет.

---

## T0.7 — Оживить админ-алерты

**Приоритет:** P1, но по последствиям близко к P0: сервис может лежать, а владелец не узнает.

**Проблема** ✅ VERIFIED лично, и это НЕ то, что сказал субагент:
```bash
$ grep -nE "ADMIN_IDS *=" bot/bot.py                        → ОПРЕДЕЛЕНИЯ НЕТ
$ ssh ... 'grep -nE "ADMIN_IDS *=" /opt/mosaic-bot/bot.py'  → ОПРЕДЕЛЕНИЯ НЕТ
$ ssh ... 'cat /opt/mosaic-bot/admins.txt'                  → файла нет
$ ssh ... 'journalctl -u mosaic-bot --since "48 hours ago" | grep -c NameError' → 0
```
`ADMIN_IDS` используется в 7 местах (1183, 1854, 1987, 2082, 2107, 2122, 2157) и **нигде не
определён**. Субагент решил, что хендлеры «упадут с NameError» — не упадут: всё обёрнуто в
`try/except Exception`, ошибка глотается молча. Практический итог: `admin_alert()` (1181)
никогда ничего не отправляет, `check_and_alert()` крутится каждые 300 с впустую, команды
`/admin`, `/top`, `/promo`, `/tickets` мертвы.

Плюс: в файле **два несогласованных механизма админства** — рабочий `is_admin()` (читает
`admins.txt`, дефолтный ID `583864`) и сломанный `ADMIN_IDS`.

**Шаги.**

1. Свести к одному источнику: оставить `is_admin()`, добавить рядом
```python
def admin_ids():
    """Единый источник списка админов. Читает admins.txt, дефолт — ADMIN_FALLBACK_ID из env."""
```
2. Заменить все 7 вхождений `ADMIN_IDS` на `admin_ids()`.
3. Убрать `try/except Exception: pass`, которые глотают ошибки доставки алерта — логировать
   через `logger.error` с трейсом.
4. Создать `/opt/mosaic-bot/admins.txt` с реальным ID владельца — **спросить у владельца,
   не выдумывать**. Пока не дан — брать из env `ADMIN_FALLBACK_ID`.
5. Проверка живьём: временно понизить порог в `check_and_alert()`, убедиться, что сообщение
   реально приходит в Telegram, вернуть порог. Вывод `journalctl` — в отчёт.

**Приёмка:** алерт физически доставлен в Telegram (скриншот или строка лога с успешным
`send_message`), а не «код выглядит правильно».
