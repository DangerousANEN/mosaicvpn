# MosaicVPN Smart Groups: Разделы 2.4, 3, 4, 5

---

## 2.4 ФОРМУЛЫ РАНЖИРОВАНИЯ И COMPOSITE SCORE

### Метрики в таблице `node_metrics`

```sql
CREATE TABLE node_metrics (
    node_id         UUID PRIMARY KEY REFERENCES nodes(id),
    rtt_p50_ms      FLOAT,      -- медиана RTT (мс)
    rtt_p95_ms      FLOAT,      -- хвост RTT
    jitter_ms       FLOAT,      -- среднеквадр. отклонение RTT
    loss_pct        FLOAT,      -- % потерь пакетов (0-100)
    throughput_mbps FLOAT,      -- измеренный throughput
    uptime_pct      FLOAT,      -- % аптайма за 7 дней (0-100)
    failure_count   INT,        -- кол-во падений за 24ч
    node_age_days   INT,        -- возраст ноды в днях
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
```

---

### Формула `min_latency` (цель: минимальный отклик)

```
score_latency = 1 / (
    0.50 * normalize(rtt_p50_ms)   +   -- основной вес: медиана RTT
    0.25 * normalize(jitter_ms)    +   -- стабильность задержки
    0.15 * normalize(rtt_p95_ms)   +   -- хвостовые задержки
    0.10 * normalize(loss_pct)         -- потери пакетов
)
```

**Нормализация** — min-max по пулу нод группы:
```
normalize(x) = (x - min_pool) / (max_pool - min_pool + ε)
```
где `ε = 0.001` защита от деления на ноль.

**Итог**: чем меньше RTT/jitter/loss → тем выше `score_latency`.

---

### Формула `max_speed` (цель: максимальная пропускная способность)

```
score_speed =
    0.70 * normalize_inv(throughput_mbps)  +   -- главный фактор
    0.20 * normalize(rtt_p50_ms)           +   -- RTT влияет на TCP goodput
    0.10 * normalize(loss_pct)                 -- потери режут throughput
```

`normalize_inv(x) = 1 - normalize(x)` — инвертируем, т.к. больше = лучше:
```
normalize_inv(throughput) = (throughput - min_pool) / (max_pool - min_pool + ε)
-- НЕ инвертируем, просто: выше throughput → выше score
```

Точнее:
```
score_speed =
    0.70 * (throughput_mbps / max_throughput_in_pool)  +
    0.20 * (1 - rtt_p50_ms / max_rtt_in_pool)         +
    0.10 * (1 - loss_pct / 100)
```

---

### Формула `stable` (цель: надёжность и предсказуемость)

```
score_stable =
    0.50 * (uptime_pct / 100)                              +
    0.30 * (1 - min(failure_count, 10) / 10)               +
    0.20 * sigmoid(node_age_days, midpoint=30, k=0.1)
```

**Sigmoid зрелости ноды** (новые ноды получают штраф):
```
sigmoid(age, midpoint, k) = 1 / (1 + exp(-k * (age - midpoint)))
```
- age=0 дней → sigmoid ≈ 0.05 (штраф)
- age=30 дней → sigmoid = 0.50
- age=90+ дней → sigmoid ≈ 0.95 (бонус)

---

### SQL: обновление score и привязка нод к группам

```sql
-- ШАГ 1: Вычисляем нормализованные метрики по пулу каждой группы
WITH pool_stats AS (
    SELECT
        sg.id                          AS group_id,
        sg.strategy,
        n.id                           AS node_id,
        nm.rtt_p50_ms,
        nm.jitter_ms,
        nm.rtt_p95_ms,
        nm.loss_pct,
        nm.throughput_mbps,
        nm.uptime_pct,
        nm.failure_count,
        nm.node_age_days,
        -- min/max по пулу группы
        MIN(nm.rtt_p50_ms)      OVER w AS min_rtt,
        MAX(nm.rtt_p50_ms)      OVER w AS max_rtt,
        MIN(nm.jitter_ms)       OVER w AS min_jitter,
        MAX(nm.jitter_ms)       OVER w AS max_jitter,
        MIN(nm.rtt_p95_ms)      OVER w AS min_rtt95,
        MAX(nm.rtt_p95_ms)      OVER w AS max_rtt95,
        MIN(nm.loss_pct)        OVER w AS min_loss,
        MAX(nm.loss_pct)        OVER w AS max_loss,
        MIN(nm.throughput_mbps) OVER w AS min_tput,
        MAX(nm.throughput_mbps) OVER w AS max_tput
    FROM smart_groups sg
    JOIN group_node_pool gnp ON gnp.group_id = sg.id
    JOIN nodes n              ON n.id = gnp.node_id
    JOIN node_metrics nm      ON nm.node_id = n.id
    WHERE n.is_active = TRUE
      AND nm.updated_at > NOW() - INTERVAL '15 minutes'
    WINDOW w AS (PARTITION BY sg.id)
),

-- ШАГ 2: Считаем composite score по стратегии
scored AS (
    SELECT
        group_id,
        strategy,
        node_id,
        CASE strategy
            WHEN 'min_latency' THEN
                1.0 / NULLIF(
                    0.50 * (rtt_p50_ms - min_rtt)      / NULLIF(max_rtt - min_rtt, 0)      +
                    0.25 * (jitter_ms  - min_jitter)   / NULLIF(max_jitter - min_jitter, 0) +
                    0.15 * (rtt_p95_ms - min_rtt95)    / NULLIF(max_rtt95 - min_rtt95, 0)   +
                    0.10 * (loss_pct   - min_loss)      / NULLIF(max_loss - min_loss, 0)
                + 0.001, 0)

            WHEN 'max_speed' THEN
                0.70 * (throughput_mbps - min_tput) / NULLIF(max_tput - min_tput, 0) +
                0.20 * (1 - (rtt_p50_ms - min_rtt)  / NULLIF(max_rtt - min_rtt, 0)) +
                0.10 * (1 - loss_pct / 100.0)

            WHEN 'stable' THEN
                0.50 * (uptime_pct / 100.0) +
                0.30 * (1 - LEAST(failure_count, 10) / 10.0) +
                0.20 * (1.0 / (1.0 + EXP(-0.1 * (node_age_days - 30))))

            ELSE 0
        END AS composite_score
    FROM pool_stats
),

-- ШАГ 3: Ранжируем ноды внутри группы
ranked AS (
    SELECT
        group_id,
        node_id,
        composite_score,
        ROW_NUMBER() OVER (
            PARTITION BY group_id
            ORDER BY composite_score DESC
        ) AS rank_in_group
    FROM scored
    WHERE composite_score IS NOT NULL
)

-- ШАГ 4: Обновляем таблицу привязки нод к группам
INSERT INTO group_node_assignments (group_id, node_id, composite_score, rank_in_group, assigned_at)
SELECT
    group_id,
    node_id,
    composite_score,
    rank_in_group,
    NOW()
FROM ranked
ON CONFLICT (group_id, node_id) DO UPDATE SET
    composite_score = EXCLUDED.composite_score,
    rank_in_group   = EXCLUDED.rank_in_group,
    assigned_at     = EXCLUDED.assigned_at;
```

```sql
-- ШАГ 5: Помечаем топ-N нод как активные кандидаты для выдачи
UPDATE group_node_assignments
SET is_candidate = (rank_in_group <= 20)  -- топ-20 в пуле сервера
WHERE assigned_at > NOW() - INTERVAL '1 minute';
```

---

## 3. ВЫДАЧА КАНДИДАТОВ И ШАРДИНГ (FEED DELIVERY)

### Почему нельзя отдавать все 80 нод клиенту

| Проблема | Детали |
|---|---|
| **CPU/батарея** | urltest запускает параллельные HTTP-запросы. 80 нод = 80 goroutine-эквивалентов в sing-box, постоянный wake-lock |
| **DNS** | Каждая нода = отдельный hostname. 80 DNS-резолюций при каждом цикле urltest (каждые 3 мин) = DNS flood, кэш переполнен |
| **Socket limits Android** | Android ограничивает кол-во одновременных сокетов на процесс (~1024 fd). При 80 нодах + overhead VPN-стека риск `EMFILE` |
| **Время первого подключения** | urltest на 80 нод занимает 5-15 сек до выбора лучшей. Пользователь ждёт |
| **Трафик** | 80 × HTTP HEAD к test-URL каждые 3 мин = ~14400 запросов/час на устройство |

**Вывод**: сервер делает тяжёлую работу (мониторинг 80 нод), клиент получает уже отфильтрованный топ.

---

### Сколько нод отдавать клиенту

```
Оптимум: 5-7 нод на группу
```

**Обоснование**:
- **5 нод** — минимум для failover (если 2 легли, остаётся 3 рабочих)
- **7 нод** — баланс: urltest за ~800мс на LTE, покрытие географии
- **>8 нод** — diminishing returns, рост нагрузки нелинейный

```
Рекомендация по типу группы:
  min_latency → 5 нод  (нужна точность, не разнообразие)
  max_speed   → 6 нод  (throughput варьируется, нужен выбор)
  stable      → 7 нод  (запас на случай падений)
```

---

### Алгоритм детерминированного шардинга

**Цель**: разные пользователи получают разные подмножества из топ-20 пула → равномерная нагрузка на ноды.

```python
import hashlib

def get_candidate_nodes(
    subscriber_uuid: str,
    group_id: str,
    pool: list[Node],      # топ-20 нод, отсортированных по composite_score
    shard_size: int = 6,   # нод на клиента
    pool_size: int = 20
) -> list[Node]:
    """
    Детерминированный выбор подмножества нод для конкретного пользователя.
    Один и тот же пользователь всегда получает одно подмножество
    (до следующего пересчёта пула).
    """
    # Детерминированный seed: uuid + group + дата (ротация раз в сутки)
    from datetime import date
    seed_str = f"{subscriber_uuid}:{group_id}:{date.today().isoformat()}"
    seed_hash = int(hashlib.sha256(seed_str.encode()).hexdigest(), 16)

    # Гарантируем топ-1 ноду всегда (лучшая по score)
    top_node = pool[0]

    # Из оставшихся pool_size-1 нод выбираем shard_size-1
    remaining = pool[1:pool_size]
    selected = []
    available = list(range(len(remaining)))

    rng_state = seed_hash
    for _ in range(shard_size - 1):
        if not available:
            break
        idx = rng_state % len(available)
        selected.append(remaining[available[idx]])
        available.pop(idx)
        # LCG для следующей итерации
        rng_state = (rng_state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF

    return [top_node] + selected
```

**SQL-сторона** (API endpoint):

```sql
-- Получаем топ-20 кандидатов для группы
SELECT
    n.id,
    n.address,
    n.port,
    n.protocol,
    n.config_json,
    gna.composite_score,
    gna.rank_in_group
FROM group_node_assignments gna
JOIN nodes n ON n.id = gna.node_id
WHERE gna.group_id = $1
  AND gna.is_candidate = TRUE
  AND n.is_active = TRUE
ORDER BY gna.rank_in_group ASC
LIMIT 20;
-- Шардинг применяется в application layer (Python/Go)
```

**Ротация шарда**: `date.today()` в seed → каждые сутки пользователь получает новое подмножество. Для более частой ротации: `datetime.now().hour` → каждый час.

---

## 4. АВТОВЫБОР И FAILOVER НА КЛИЕНТЕ

### Почему гибрид (серверный скоринг + локальный urltest на 5-7) лучше

| Подход | Проблемы |
|---|---|
| **Чистый urltest на 80 нод** | CPU/батарея, медленный старт, DNS flood (см. раздел 3) |
| **Ручной клиентский замер** | Пользователь не знает критериев, субъективно, нет автообновления |
| **Только серверный скоринг** | Не учитывает локальную сеть клиента (ISP, геолокация, NAT-тип) |
| **✅ Гибрид** | Сервер отсеивает глобально плохие ноды → клиент выбирает лучшую для своей сети |

**Гибридная логика**:
```
Сервер:  глобальные метрики (RTT из ДЦ, uptime