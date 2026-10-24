# Бенчмарк поиска товаров — NFR-PERF-001 (RM-E-005, T-PERF-002)

Дата прогона: 2026-10-22 (запуск 2026-10-22 06:00 UTC). Задача: RM-E-005 (13_IMPLEMENTATION_ROADMAP §3.5). Цель: **p95 ≤ 300 мс при 50 000 SKU** (01 NFR-PERF-001, 08 §4.5.1). Метод — 12 T-PERF-002: `autocannon -c 50 -d 60` по 20 запросам.

> **Тестовые данные.** Каталог синтетический: 50 000 SKU из `scripts/seed_synthetic_catalog.ts`, загруженные конвейером применения 1С RM-E-001 из `FakeOnecGateway`. Это не реальная интеграция и не данные заказчика. Образцов каталога заказчика нет (Q-040), поэтому замер на реальных данных и на целевом сервере остаётся за RM-H-004 (k6, T-PERF-001).

## 1. Итог

| Показатель | Цель | Факт (50 000 SKU, 50 соединений, 60 с) | Статус |
|---|---|---|---|
| p95 `GET /search/products`, смесь 20 запросов | ≤ 300 мс | **169.8 мс** (p50 78.9 мс, p99 227.8 мс, max 351.0 мс) | **достигнуто** на стенде разработчика |
| Ошибки / не-2xx | < 0,1 % | 0 / 0 из 33192 | достигнуто |
| `matchType` по эталонному набору | 100 % ожидаемых | 20 из 20 (таблица §5) | достигнуто |
| Пропускная способность | — (справочно) | 553.2 запросов/с | — |

Худшая группа запросов — «название» (FTS и триграммы): p95 193.8 мс. Худший отдельный запрос — `радиатор` с `inStock=true` и `sort=price:asc`: p95 283.3 мс. У него 1 729 совпадений, и для каждого считаются агрегаты цены и остатка.

**Ограничение вывода.** Нагрузка — замкнутый цикл: 50 соединений шлют запросы без пауз. Это жёстче профиля T-PERF-001 (50 VU с паузами). Сервер — один процесс Node; ограничивает его CPU event loop: загрузка 94.5 %, 1.8 мс CPU на запрос. Поэтому при числе одновременных запросов больше ~50 p95 растёт почти линейно. Цель подтверждается на синтетике и этом стенде. Повторить замер на целевом сервере (Linux, 4–8 vCPU) с полным pos-api (JWT, все модули) должна задача RM-H-004.

## 2. Стенд

| Параметр | Значение |
|---|---|
| CPU | 13th Gen Intel(R) Core(TM) i7-13650HX, 20 логических ядер |
| RAM | 16 ГБ |
| ОС | Windows 11 Pro (win32 10.0.26200) |
| Node.js | v24.11.1 |
| PostgreSQL | PostgreSQL 17.10, embedded (`embedded-postgres`), `fsync=off`, остальные настройки по умолчанию (`shared_buffers` 128 МБ). БД создана с `LC_CTYPE 'en-US'` (§7 п. 5, EQ-SRCH-01) |
| Сервер поиска | отдельный процесс Node: Nest + Express, `SearchModule`, инфраструктура common (Config, Logging pino уровня `info`, Rbac guard, фильтр Problem, ValidationPipe), пул `pg` из `createPool` прода (max 10), 1 процесс |
| Генератор нагрузки | autocannon 8.0.0 (программно, отдельный процесс) на той же машине |

Чем сервер бенчмарка отличается от боевого pos-api: субъект запроса задаётся заголовком `x-test-principal` (роль `seller`), а AuthGuard (проверка JWT ES256) и SessionActivityGuard не подключены. Остальной путь запроса тот же: RbacGuard (`search.read`), `CatalogViewerService` (вид цены, склад), `CatalogProductsService.summaries` (карточки), фильтр Problem, журнал pino-http. Проверка JWT стоит доли миллисекунды CPU на запрос. Её добавит прогон RM-H-004 на полном стеке.

## 3. Данные

`scripts/seed_synthetic_catalog.ts --sku 50000 --seed 1` (основа RM-E-001), загрузка за 85 с:

| Сущность | Строк |
|---|---|
| Товары (`products`; продаваемые и не помеченные на удаление) | 50 000 (49 502) |
| Варианты (`product_variants`, вместе со служебными) | 80 281 |
| Штрихкоды | 89 573 |
| Цены (3 вида цен) | 265 166 |
| Остатки (3 склада) | 147 668 |
| Категории | 93 |
| Упаковки | 19 371 |

Размеры: `products` — 173 MB, GIN `search_vector` — 5040 kB, GIN trgm `name_norm` — 15 MB, GIN trgm `sku_norm` (0005) — 3768 kB, словарь `search_words` (0005) — 35 888 слов.

## 4. Как воспроизвести

```bash
cd pos-api
export TEMP=../.tmp TMP=../.tmp            # на Windows: на диске C: мало места
npm run bench:search -- --sku 50000 --duration 60 --warmup 10 --connections 50 \
  --json ../.tmp/search-bench.json --report ../.tmp/search-bench.md
# код выхода 0 — p95 ≤ 300 мс, ошибок нет, все matchType ожидаемые; 1 — иначе
```

Скрипт `test/search/bench/search-bench.ts` выполняет шаги по порядку:

1. embedded PostgreSQL 17;
2. все `migrations/*.sql`;
3. `seed_synthetic_catalog.ts`;
4. `VACUUM ANALYZE`;
5. сборка сервера: `tsc -p test/search/bench/tsconfig.bench.json`;
6. запуск `bench-server.ts`;
7. прогрев: 3 круга по 20 запросов с проверкой `matchType`, затем 10 с нагрузки без учёта;
8. замер;
9. EXPLAIN (ANALYZE, BUFFERS);
10. отчёт.

Сервер собирается через `tsc`, потому что Nest DI нужен `emitDecoratorMetadata`, а tsx/esbuild его не выпускают. Кластер, процессы и каталог сборки удаляются в `finally`. Дополнительные параметры: `--url` (готовая БД), `--kinds barcode,sku,name`, `--workers N` (node:cluster), `--log-level`, `--skip-explain`.

Смесь запросов — по 12 T-PERF-002 и §8: 20 запросов, autocannon перебирает их по кругу на каждом соединении. Артикул — 6 запросов (30 %), название — 10 (50 %), штрихкод — 4 (20 %). Все запросы — `GET /api/v1/search/products?q=…&limit=40`.

## 5. Результаты

Задержка на клиенте (autocannon), мс. Колонка «сервер» — время обработки внутри процесса: от входа запроса в Express до события `finish`.

| Группа | n | p50 | p95 | p99 | max | p95 на сервере |
|---|---|---|---|---|---|---|
| все | 33192 | 78.9 | **169.8** | 227.8 | 351.0 | — |
| штрихкод (4 запроса) | 6737 | 60.2 | 95.0 | 132.6 | 233.0 | 91.6 |
| артикул (6) | 9984 | 66.0 | 116.6 | 141.5 | 205.0 | 111.0 |
| название (10) | 16471 | 99.4 | 193.8 | 252.5 | 351.0 | 189.2 |

По запросам (`найдено` — `matchTypes[<ступень>]`, то есть число совпадений выбранной ступени D-31):

| Запрос | `q` | Вид | matchType | найдено | n | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|
| штрихкод #1 | `2100000001002` | barcode | barcode | 1 | 1690 | 71.0 | 127.3 | 167.8 | 233.0 |
| штрихкод #2 | `2100000711017` | barcode | barcode | 1 | 1687 | 60.6 | 86.2 | 102.1 | 124.2 |
| штрихкод #3 | `2100000711024` | barcode | barcode | 1 | 1682 | 56.5 | 80.7 | 95.9 | 109.8 |
| штрихкод #4 | `2100000712007` | barcode | barcode | 1 | 1678 | 55.9 | 77.8 | 93.3 | 113.4 |
| артикул точный | `F4252` | sku | sku | 1 | 1676 | 55.1 | 78.6 | 96.2 | 140.7 |
| артикул с дефисом | `G1017-8` | sku | sku | 1 | 1673 | 55.9 | 78.3 | 100.2 | 147.0 |
| артикул без дефиса | `VTP20` | sku | sku | 1 | 1667 | 58.6 | 81.8 | 99.1 | 143.5 |
| префикс артикула | `F42` | sku | sku | 49 | 1663 | 67.3 | 93.2 | 115.2 | 155.6 |
| префикс артикула 2 | `HB15` | sku | sku | 64 | 1655 | 72.0 | 119.1 | 136.4 | 151.1 |
| артикул с опечаткой | `SB-1WJ` | sku | trgm | 1 | 1650 | 103.6 | 141.7 | 176.9 | 205.0 |
| одно слово (много совпадений) | `смеситель` | name | fts | 4944 | 1650 | 121.5 | 165.0 | 191.5 | 222.3 |
| кириллица + бренд транслитом | `смеситель фрап` | name | fts | 669 | 1650 | 86.6 | 132.5 | 145.1 | 152.2 |
| бренд + модель | `Frap F4252` | name | fts | 1 | 1650 | 76.1 | 105.6 | 123.4 | 159.7 |
| два слова | `унитаз компакт` | name | fts | 1017 | 1649 | 82.0 | 117.3 | 146.2 | 165.1 |
| слово + число | `труба ппр 20` | name | fts | 1 | 1649 | 77.4 | 112.9 | 145.2 | 161.2 |
| ввод по буквам (префикс) | `кран шар` | name | fts | 1013 | 1648 | 84.2 | 120.4 | 137.9 | 153.8 |
| опечатка в названии | `смиситель` | name | trgm | 4944 | 1646 | 142.1 | 202.2 | 247.1 | 260.3 |
| ё/е и регистр | `КОТЕЛ ГАЗОВЫЙ` | name | fts | 1002 | 1645 | 94.5 | 138.0 | 181.7 | 198.5 |
| раскладка (cvtcbntkm) | `cvtcbntkm` | name | fts | 4944 | 1643 | 142.5 | 191.8 | 228.3 | 284.8 |
| фильтр inStock + sort=price:asc | `радиатор` `inStock=true` `sort=price:asc` | name | fts | 1729 | 1641 | 181.9 | 283.3 | 303.8 | 351.0 |

Сервер за 60 с израсходовал 54.6 с CPU user и 4.4 с system, то есть **1.8 мс CPU на запрос**; загрузка event loop — **94.5 %**. Узкое место — CPU процесса Node: построение 40 карточек `ProductSummary` (decimal.js, даты), `JSON.stringify` ответа около 37 КБ, разбор строк `pg`, журнал pino. Время в PostgreSQL у типичного запроса — 0,1–15 мс (EXPLAIN, §6).

### 5.1. Как получен результат: история прогонов на 50 000 SKU

| Прогон | Изменение | p50 / p95 / p99, мс | Запросов/с |
|---|---|---|---|
| 1 | первая реализация: `ts_rank_cd`, транзакция на каждый поиск, FTS повторно выбирает товары по id | 327 / 816 / 1128 | 133 |
| 2 | в транзакции поиска выключены параллельные планы и JIT: запуск параллельных воркеров PostgreSQL занимал около 160 мс при 25 мс полезной работы (`Gather Merge`, прогон 1); FTS выбирает совпадения прямо из `products` | 192 / 427 / 520 | 227 |
| 3 | `ts_rank` вместо `ts_rank_cd` (запрос с вариантами слова и префиксом: 3,7 мс вместо 78 мс); кэш контекста зрителя на 3 с и среза на 2 с; штрихкод и артикул ищутся без транзакции; начало транзакции — один round-trip | 155 / 409 / 607 (короткий замер, 30 с) | 272 |
| 4 | опечатка в названии исправляется по словарю `search_words` (0005): 0,07 мс на словарь плюс 9 мс на FTS вместо `word_similarity` по ~3 000 названиям (57–80 мс) | 81 / 177 / 248 (20 с) | 544 |
| **итог** | то же, плюс прогрев 10 с; полный конвейер: новая БД, seed, замер 60 с | **78.9 / 169.8 / 227.8** | **553.2** |

Прогоны 3–4 — короткие замеры на уже заполненной БД (`--url`). От замера к замеру p95 менялся на 15–30 % (прогрев V8, кэш страниц), поэтому в итоговом прогоне есть 10 с прогрева.

Профиль CPU сервера выявил ещё одну затрату. Если журнал пишется на уровне `warn`, а не `info`, CPU на запрос падает с 2,6 до 2,2 мс. Причина — в `common/logging`: `sanitizeLogValue` в `hooks.logMethod` и `formatters.log` обходит на глубину 8 сырой `ServerResponse` из pino-http, ещё до сериализаторов. Это 8–10 % CPU процесса (EQ-SRCH-16, передано владельцу `common/logging`).

## 6. Планы ключевых запросов: EXPLAIN (ANALYZE, BUFFERS, COSTS OFF), 50 000 SKU

Условия съёмки планов: транзакция поиска (`SEARCH_TX_BEGIN`: `max_parallel_workers_per_gather = 0`, `jit = off`, пороги pg_trgm), роль `seller`, вид цены «Розничная», первый склад, `limit=40`.

Используются индексы:

- `barcodes_value_uq`;
- `products_sku_norm_idx` и `product_variants_sku_norm_idx` (префикс через `~>=~` / `~<~`);
- `products_onec_code_idx`;
- GIN `products_search_vector_gin`;
- GIN trgm: `products_name_norm_trgm`, `products_sku_norm_trgm`, `product_variants_*_trgm` (0005);
- `search_words_word_trgm` (0005);
- `products_name_norm_prefix_idx` (0005, подсказки).

Полного чтения `products` нет ни в одном плане. Планирование при первом вызове занимает 2–7 мс; в установившемся режиме меньше, потому что соединения пула переиспользуются и кэш каталога прогрет.

### 6.1. barcode: q=2100000001002

```text
Limit (actual time=0.064..0.065 rows=1 loops=1)
  Buffers: shared hit=11
  CTE k
    ->  Nested Loop (actual time=0.042..0.042 rows=1 loops=1)
          Buffers: shared hit=8
          ->  GroupAggregate (actual time=0.026..0.026 rows=1 loops=1)
                Group Key: b.product_id
                Buffers: shared hit=4
                ->  Sort (actual time=0.023..0.024 rows=1 loops=1)
                      Sort Key: b.product_id
                      Sort Method: quicksort  Memory: 25kB
                      Buffers: shared hit=4
                      ->  Index Scan using barcodes_value_uq on barcodes b (actual time=0.019..0.019 rows=1 loops=1)
                            Index Cond: (value = '2100000001002'::text)
                            Filter: (NOT deletion_mark)
                            Buffers: shared hit=4
          ->  Index Scan using products_pkey on products p (actual time=0.014..0.014 rows=1 loops=1)
                Index Cond: (id = b.product_id)
                Filter: ((NOT deletion_mark) AND is_sellable)
                Buffers: shared hit=4
  InitPlan 2
    ->  Aggregate (actual time=0.001..0.001 rows=1 loops=1)
          ->  CTE Scan on k k_1 (actual time=0.000..0.001 rows=1 loops=1)
  ->  Sort (actual time=0.063..0.063 rows=1 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=11
        ->  CTE Scan on k (actual time=0.047..0.047 rows=1 loops=1)
              Buffers: shared hit=8
Planning:
  Buffers: shared hit=390
Planning Time: 6.884 ms
Execution Time: 0.128 ms
```

### 6.2. sku: q=F42 (префикс)

```text
Limit (actual time=0.610..0.615 rows=41 loops=1)
  Buffers: shared hit=272
  CTE k
    ->  Nested Loop (actual time=0.257..0.562 rows=49 loops=1)
          Buffers: shared hit=272
          ->  GroupAggregate (actual time=0.250..0.264 rows=51 loops=1)
                Group Key: products.id
                Buffers: shared hit=68
                ->  Sort (actual time=0.246..0.250 rows=64 loops=1)
                      Sort Key: products.id
                      Sort Method: quicksort  Memory: 27kB
                      Buffers: shared hit=68
                      ->  Append (actual time=0.027..0.232 rows=64 loops=1)
                            Buffers: shared hit=68
                            ->  Index Scan using products_sku_norm_idx on products (actual time=0.015..0.015 rows=0 loops=1)
                                  Index Cond: (sku_norm = 'F42'::text)
                                  Buffers: shared hit=2
                            ->  Subquery Scan on "*SELECT* 2" (actual time=0.011..0.148 rows=51 loops=1)
                                  Buffers: shared hit=53
                                  ->  Index Scan using products_sku_norm_idx on products products_1 (actual time=0.010..0.144 rows=51 loops=1)
                                        Index Cond: ((sku_norm ~>=~ 'F42'::text) AND (sku_norm ~<~ 'F43'::text))
                                        Filter: (sku_norm ~~ 'F42%'::text)
                                        Buffers: shared hit=53
                            ->  Subquery Scan on "*SELECT* 3" (actual time=0.018..0.052 rows=13 loops=1)
                                  Buffers: shared hit=10
                                  ->  Index Scan using product_variants_sku_norm_idx on product_variants v (actual time=0.018..0.051 rows=13 loops=1)
                                        Index Cond: ((sku_norm ~>=~ 'F42'::text) AND (sku_norm ~<~ 'F43'::text))
                                        Filter: ((NOT deletion_mark) AND (sku_norm ~~ 'F42%'::text))
                                        Buffers: shared hit=10
                            ->  Subquery Scan on "*SELECT* 4" (actual time=0.013..0.013 rows=0 loops=1)
                                  Buffers: shared hit=3
                                  ->  Index Scan using products_onec_code_idx on products products_2 (actual time=0.013..0.013 rows=0 loops=1)
                                        Index Cond: (onec_code = 'F42'::text)
                                        Buffers: shared hit=3
          ->  Index Scan using products_pkey on products p (actual time=0.006..0.006 rows=1 loops=51)
                Index Cond: (id = products.id)
                Filter: ((NOT deletion_mark) AND is_sellable)
                Rows Removed by Filter: 0
                Buffers: shared hit=204
  InitPlan 2
    ->  Aggregate (actual time=0.317..0.317 rows=1 loops=1)
          Buffers: shared hit=200
          ->  CTE Scan on k k_1 (actual time=0.000..0.314 rows=49 loops=1)
                Buffers: shared hit=200
  ->  Sort (actual time=0.610..0.611 rows=41 loops=1)
        Sort Key: k.k_score DESC, k.k_name, k.id
        Sort Method: quicksort  Memory: 35kB
        Buffers: shared hit=272
        ->  CTE Scan on k (actual time=0.578..0.584 rows=49 loops=1)
              Buffers: shared hit=272
Planning:
  Buffers: shared hit=195
Planning Time: 3.713 ms
Execution Time: 0.684 ms
```

### 6.3. fts: q=смеситель (много совпадений)

```text
Limit (actual time=13.417..13.421 rows=41 loops=1)
  Buffers: shared hit=3900
  CTE k
    ->  Bitmap Heap Scan on products p (actual time=1.781..11.441 rows=4944 loops=1)
          Recheck Cond: (search_vector @@ '''смесител'':* | ''smesitel'':* | ''cvtcbntkm'':*'::tsquery)
          Filter: ((NOT deletion_mark) AND is_sellable)
          Rows Removed by Filter: 47
          Heap Blocks: exact=3889
          Buffers: shared hit=3900
          ->  Bitmap Index Scan on products_search_vector_gin (actual time=1.380..1.380 rows=4991 loops=1)
                Index Cond: (search_vector @@ '''смесител'':* | ''smesitel'':* | ''cvtcbntkm'':*'::tsquery)
                Buffers: shared hit=11
  InitPlan 2
    ->  Aggregate (actual time=10.423..10.423 rows=1 loops=1)
          Buffers: shared hit=3888
          ->  CTE Scan on k k_1 (actual time=0.000..10.255 rows=4944 loops=1)
                Buffers: shared hit=3888
  ->  Sort (actual time=13.416..13.417 rows=41 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: top-N heapsort  Memory: 32kB
        Buffers: shared hit=3900
        ->  CTE Scan on k (actual time=12.212..12.846 rows=4944 loops=1)
              Buffers: shared hit=3900
Planning:
  Buffers: shared hit=47
Planning Time: 2.016 ms
Execution Time: 13.672 ms
```

### 6.4. fts: q=смеситель фрап (транслитерация)

```text
Limit (actual time=2.479..2.484 rows=41 loops=1)
  Buffers: shared hit=674
  CTE k
    ->  Bitmap Heap Scan on products p (actual time=1.347..2.181 rows=669 loops=1)
          Recheck Cond: (search_vector @@ '( ''смесител'' | ''smesitel'' | ''cvtcbntkm'' ) & ( ''фрап'':* | ''frap'':* | ''ahfg'':* )'::tsquery)
          Filter: ((NOT deletion_mark) AND is_sellable)
          Rows Removed by Filter: 9
          Heap Blocks: exact=652
          Buffers: shared hit=674
          ->  Bitmap Index Scan on products_search_vector_gin (actual time=1.295..1.295 rows=678 loops=1)
                Index Cond: (search_vector @@ '( ''смесител'' | ''smesitel'' | ''cvtcbntkm'' ) & ( ''фрап'':* | ''frap'':* | ''ahfg'':* )'::tsquery)
                Buffers: shared hit=22
  InitPlan 2
    ->  Aggregate (actual time=0.930..0.930 rows=1 loops=1)
          Buffers: shared hit=651
          ->  CTE Scan on k k_1 (actual time=0.000..0.907 rows=669 loops=1)
                Buffers: shared hit=651
  ->  Sort (actual time=2.479..2.482 rows=41 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: top-N heapsort  Memory: 34kB
        Buffers: shared hit=674
        ->  CTE Scan on k (actual time=2.281..2.374 rows=669 loops=1)
              Buffers: shared hit=674
Planning:
  Buffers: shared hit=1
Planning Time: 0.217 ms
Execution Time: 2.572 ms
```

### 6.5. fts: q=радиатор, inStock=true, sort=price:asc

```text
Limit (actual time=34.301..34.307 rows=41 loops=1)
  Buffers: shared hit=46518
  CTE k
    ->  Nested Loop (actual time=0.928..33.044 rows=1729 loops=1)
          Buffers: shared hit=46515
          ->  Nested Loop Left Join (actual time=0.914..20.979 rows=2335 loops=1)
                Buffers: shared hit=24814
                ->  Bitmap Heap Scan on products p (actual time=0.883..4.815 rows=2335 loops=1)
                      Recheck Cond: (search_vector @@ '''радиатор'':* | ''radiat'':* | ''hflbfnjh'':*'::tsquery)
                      Filter: ((NOT deletion_mark) AND is_sellable)
                      Rows Removed by Filter: 18
                      Heap Blocks: exact=2123
                      Buffers: shared hit=2131
                      ->  Bitmap Index Scan on products_search_vector_gin (actual time=0.714..0.715 rows=2353 loops=1)
                            Index Cond: (search_vector @@ '''радиатор'':* | ''radiat'':* | ''hflbfnjh'':*'::tsquery)
                            Buffers: shared hit=8
                ->  Aggregate (actual time=0.007..0.007 rows=1 loops=2335)
                      Buffers: shared hit=22683
                      ->  Nested Loop (actual time=0.006..0.006 rows=1 loops=2335)
                            Buffers: shared hit=22683
                            ->  Index Scan using product_variants_product_idx on product_variants v (actual time=0.002..0.002 rows=1 loops=2335)
                                  Index Cond: (product_id = p.id)
                                  Filter: (is_default = (NOT p.has_variants))
                                  Rows Removed by Filter: 0
                                  Buffers: shared hit=9811
                            ->  Index Scan using prices_list_variant_idx on prices x (actual time=0.002..0.003 rows=1 loops=3218)
                                  Index Cond: ((price_list_id = '01a16233-1056-7379-9bb9-149576f94fd3'::uuid) AND (variant_id = v.id))
                                  Filter: (packaging_id IS NULL)
                                  Buffers: shared hit=12872
          ->  Aggregate (actual time=0.005..0.005 rows=1 loops=2335)
                Filter: (sum(b.available) > '0'::numeric)
                Rows Removed by Filter: 0
                Buffers: shared hit=21701
                ->  Nested Loop (actual time=0.004..0.005 rows=1 loops=2335)
                      Buffers: shared hit=21701
                      ->  Index Scan using product_variants_product_idx on product_variants v_1 (actual time=0.001..0.001 rows=1 loops=2335)
                            Index Cond: (product_id = p.id)
                            Filter: (is_default = (NOT p.has_variants))
                            Rows Removed by Filter: 0
                            Buffers: shared hit=9811
                      ->  Index Scan using stock_balances_pkey on stock_balances b (actual time=0.002..0.002 rows=1 loops=3218)
                            Index Cond: ((variant_id = v_1.id) AND (warehouse_id = '01a16233-104b-706b-8bb3-5c116992f05b'::uuid))
                            Buffers: shared hit=11890
  InitPlan 2
    ->  Aggregate (actual time=32.603..32.603 rows=1 loops=1)
          Buffers: shared hit=46490
          ->  CTE Scan on k k_1 (actual time=0.000..32.470 rows=1729 loops=1)
                Buffers: shared hit=46490
  ->  Sort (actual time=34.300..34.301 rows=41 loops=1)
        Sort Key: k.k_null, k.k_price, k.id
        Sort Method: top-N heapsort  Memory: 34kB
        Buffers: shared hit=46518
        ->  CTE Scan on k (actual time=33.536..33.822 rows=1729 loops=1)
              Buffers: shared hit=46515
Planning:
  Buffers: shared hit=289
Planning Time: 5.117 ms
Execution Time: 34.491 ms
```

### 6.6. trgm, шаг 1: исправление слова «смиситель» по словарю search_words

```text
Nested Loop Left Join (actual time=0.052..0.053 rows=1 loops=1)
  Buffers: shared hit=22
  ->  Function Scan on unnest w (actual time=0.003..0.003 rows=1 loops=1)
  ->  Limit (actual time=0.047..0.047 rows=1 loops=1)
        Buffers: shared hit=22
        ->  Sort (actual time=0.047..0.047 rows=1 loops=1)
              Sort Key: ((sw.word = w.input)) DESC, (similarity(sw.word, w.input)) DESC, sw.freq DESC, sw.word
              Sort Method: quicksort  Memory: 25kB
              Buffers: shared hit=22
              ->  Bitmap Heap Scan on search_words sw (actual time=0.041..0.042 rows=1 loops=1)
                    Recheck Cond: (word % w.input)
                    Rows Removed by Index Recheck: 1
                    Filter: (similarity(word, w.input) >= '0.4'::double precision)
                    Heap Blocks: exact=1
                    Buffers: shared hit=22
                    ->  Bitmap Index Scan on search_words_word_trgm (actual time=0.023..0.023 rows=2 loops=1)
                          Index Cond: (word % w.input)
                          Buffers: shared hit=21
Planning:
  Buffers: shared hit=1
Planning Time: 0.104 ms
Execution Time: 0.069 ms
```

### 6.7. trgm, шаг 2: поиск исправленного «смеситель»

```text
Limit (actual time=8.578..8.584 rows=41 loops=1)
  Buffers: shared hit=3900
  CTE k
    ->  Bitmap Heap Scan on products p (actual time=1.816..6.144 rows=4944 loops=1)
          Recheck Cond: (search_vector @@ '''смесител'':* | ''smesitel'':* | ''cvtcbntkm'':*'::tsquery)
          Filter: ((NOT deletion_mark) AND is_sellable)
          Rows Removed by Filter: 47
          Heap Blocks: exact=3889
          Buffers: shared hit=3900
          ->  Bitmap Index Scan on products_search_vector_gin (actual time=1.442..1.442 rows=4991 loops=1)
                Index Cond: (search_vector @@ '''смесител'':* | ''smesitel'':* | ''cvtcbntkm'':*'::tsquery)
                Buffers: shared hit=11
  InitPlan 2
    ->  Aggregate (actual time=5.189..5.189 rows=1 loops=1)
          Buffers: shared hit=3888
          ->  CTE Scan on k k_1 (actual time=0.001..4.997 rows=4944 loops=1)
                Buffers: shared hit=3888
  ->  Sort (actual time=8.578..8.579 rows=41 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: top-N heapsort  Memory: 32kB
        Buffers: shared hit=3900
        ->  CTE Scan on k (actual time=7.012..7.850 rows=4944 loops=1)
              Buffers: shared hit=3900
Planning:
  Buffers: shared hit=1
Planning Time: 0.196 ms
Execution Time: 8.803 ms
```

### 6.8. trgm, запасной путь без словаря: q=смиситель (word_similarity по названиям)

```text
Limit (actual time=57.252..57.258 rows=41 loops=1)
  Buffers: shared hit=14190 read=261
  CTE k
    ->  Nested Loop (actual time=47.001..55.635 rows=2919 loops=1)
          Buffers: shared hit=14190 read=261
          ->  HashAggregate (actual time=46.969..47.355 rows=2950 loops=1)
                Group Key: products.id
                Batches: 1  Memory Usage: 385kB
                Buffers: shared hit=2601 read=50
                ->  Append (actual time=1.712..45.969 rows=2950 loops=1)
                      Buffers: shared hit=2601 read=50
                      ->  Bitmap Heap Scan on products (actual time=1.711..45.551 rows=2950 loops=1)
                            Filter: ('смиситель'::text <% name_norm)
                            Heap Blocks: exact=2517
                            Buffers: shared hit=2549 read=39
                            ->  Bitmap Index Scan on products_name_norm_trgm (actual time=1.454..1.455 rows=2950 loops=1)
                                  Index Cond: (name_norm %> 'смиситель'::text)
                                  Buffers: shared hit=32 read=39
                      ->  Bitmap Heap Scan on product_variants v (actual time=0.129..0.129 rows=0 loops=1)
                            Filter: ((NOT deletion_mark) AND (NOT is_default) AND ('смиситель'::text <% name_norm))
                            Buffers: shared hit=13 read=8
                            ->  Bitmap Index Scan on product_variants_name_norm_trgm (actual time=0.118..0.119 rows=0 loops=1)
                                  Index Cond: (name_norm %> 'смиситель'::text)
                                  Buffers: shared hit=13 read=8
                      ->  Bitmap Heap Scan on products products_1 (actual time=0.038..0.038 rows=0 loops=1)
                            Recheck Cond: (sku_norm % 'СМИСИТЕЛЬ'::text)
                            Buffers: shared hit=19 read=2
                            ->  Bitmap Index Scan on products_sku_norm_trgm (actual time=0.035..0.035 rows=0 loops=1)
                                  Index Cond: (sku_norm % 'СМИСИТЕЛЬ'::text)
                                  Buffers: shared hit=19 read=2
                      ->  Bitmap Heap Scan on product_variants v_1 (actual time=0.031..0.032 rows=0 loops=1)
                            Recheck Cond: (sku_norm % 'СМИСИТЕЛЬ'::text)
                            Filter: (NOT deletion_mark)
                            Buffers: shared hit=20 read=1
                            ->  Bitmap Index Scan on product_variants_sku_norm_trgm (actual time=0.030..0.030 rows=0 loops=1)
                                  Index Cond: (sku_norm % 'СМИСИТЕЛЬ'::text)
                                  Buffers: shared hit=20 read=1
          ->  Index Scan using products_pkey on products p (actual time=0.003..0.003 rows=1 loops=2950)
                Index Cond: (id = products.id)
                Filter: ((NOT deletion_mark) AND is_sellable)
                Rows Removed by Filter: 0
                Buffers: shared hit=11589 read=211
  InitPlan 2
    ->  Aggregate (actual time=9.388..9.389 rows=1 loops=1)
          Buffers: shared hit=11586 read=210
          ->  CTE Scan on k k_1 (actual time=0.001..9.200 rows=2919 loops=1)
                Buffers: shared hit=11586 read=210
  ->  Sort (actual time=57.251..57.252 rows=41 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: top-N heapsort  Memory: 34kB
        Buffers: shared hit=14190 read=261
        ->  CTE Scan on k (actual time=56.395..56.776 rows=2919 loops=1)
              Buffers: shared hit=14190 read=261
Planning:
  Buffers: shared hit=61
Planning Time: 2.562 ms
Execution Time: 57.706 ms
```

### 6.9. trgm: q=SB-1WJ (артикул с опечаткой)

```text
Limit (actual time=0.166..0.167 rows=1 loops=1)
  Buffers: shared hit=73
  CTE k
    ->  Nested Loop (actual time=0.158..0.159 rows=1 loops=1)
          Buffers: shared hit=73
          ->  GroupAggregate (actual time=0.149..0.150 rows=1 loops=1)
                Group Key: products.id
                Buffers: shared hit=69
                ->  Sort (actual time=0.146..0.147 rows=1 loops=1)
                      Sort Key: products.id
                      Sort Method: quicksort  Memory: 25kB
                      Buffers: shared hit=69
                      ->  Append (actual time=0.120..0.143 rows=1 loops=1)
                            Buffers: shared hit=69
                            ->  Bitmap Heap Scan on products (actual time=0.060..0.061 rows=0 loops=1)
                                  Filter: ('sb 1wj'::text <% name_norm)
                                  Buffers: shared hit=25
                                  ->  Bitmap Index Scan on products_name_norm_trgm (actual time=0.054..0.054 rows=0 loops=1)
                                        Index Cond: (name_norm %> 'sb 1wj'::text)
                                        Buffers: shared hit=25
                            ->  Bitmap Heap Scan on product_variants v (actual time=0.029..0.029 rows=0 loops=1)
                                  Filter: ((NOT deletion_mark) AND (NOT is_default) AND ('sb 1wj'::text <% name_norm))
                                  Buffers: shared hit=15
                                  ->  Bitmap Index Scan on product_variants_name_norm_trgm (actual time=0.027..0.028 rows=0 loops=1)
                                        Index Cond: (name_norm %> 'sb 1wj'::text)
                                        Buffers: shared hit=15
                            ->  Bitmap Heap Scan on products products_1 (actual time=0.030..0.030 rows=1 loops=1)
                                  Recheck Cond: (sku_norm % 'SB1WJ'::text)
                                  Heap Blocks: exact=1
                                  Buffers: shared hit=16
                                  ->  Bitmap Index Scan on products_sku_norm_trgm (actual time=0.025..0.025 rows=1 loops=1)
                                        Index Cond: (sku_norm % 'SB1WJ'::text)
                                        Buffers: shared hit=15
                            ->  Bitmap Heap Scan on product_variants v_1 (actual time=0.022..0.023 rows=0 loops=1)
                                  Recheck Cond: (sku_norm % 'SB1WJ'::text)
                                  Filter: (NOT deletion_mark)
                                  Buffers: shared hit=13
                                  ->  Bitmap Index Scan on product_variants_sku_norm_trgm (actual time=0.021..0.021 rows=0 loops=1)
                                        Index Cond: (sku_norm % 'SB1WJ'::text)
                                        Buffers: shared hit=13
          ->  Index Scan using products_pkey on products p (actual time=0.008..0.008 rows=1 loops=1)
                Index Cond: (id = products.id)
                Filter: ((NOT deletion_mark) AND is_sellable)
                Buffers: shared hit=4
  InitPlan 2
    ->  Aggregate (actual time=0.001..0.001 rows=1 loops=1)
          ->  CTE Scan on k k_1 (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=0.166..0.166 rows=1 loops=1)
        Sort Key: k.k_score DESC, k.id
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=73
        ->  CTE Scan on k (actual time=0.162..0.162 rows=1 loops=1)
              Buffers: shared hit=73
Planning:
  Buffers: shared hit=4
Planning Time: 1.164 ms
Execution Time: 0.250 ms
```

### 6.10. suggest: q=сме

```text
Limit (actual time=2.850..2.855 rows=20 loops=1)
  Buffers: shared hit=2561 read=19
  ->  Sort (actual time=2.849..2.853 rows=20 loops=1)
        Sort Key: (0), ((p.sku_norm)::text) COLLATE "C", ((p.id)::text)
        Sort Method: quicksort  Memory: 30kB
        Buffers: shared hit=2561 read=19
        ->  Result (actual time=0.206..2.842 rows=21 loops=1)
              Buffers: shared hit=2561 read=19
              ->  Append (actual time=0.204..2.837 rows=21 loops=1)
                    Buffers: shared hit=2561 read=19
                    ->  Limit (actual time=0.012..0.013 rows=0 loops=1)
                          Buffers: shared hit=2
                          ->  Sort (actual time=0.012..0.012 rows=0 loops=1)
                                Sort Key: p.sku_norm
                                Sort Method: quicksort  Memory: 25kB
                                Buffers: shared hit=2
                                ->  Index Scan using products_sku_norm_idx on products p (actual time=0.008..0.008 rows=0 loops=1)
                                      Index Cond: ((sku_norm ~>=~ 'СМЕ'::text) AND (sku_norm ~<~ 'СМЖ'::text))
                                      Filter: ((NOT deletion_mark) AND is_sellable AND (sku_norm ~~ 'СМЕ%'::text))
                                      Buffers: shared hit=2
                    ->  Limit (actual time=0.192..0.193 rows=1 loops=1)
                          Buffers: shared read=11
                          ->  Sort (actual time=0.191..0.192 rows=1 loops=1)
                                Sort Key: c.product_count_cache DESC, c.name_norm
                                Sort Method: quicksort  Memory: 25kB
                                Buffers: shared read=11
                                ->  Seq Scan on categories c (actual time=0.030..0.182 rows=1 loops=1)
                                      Filter: ((NOT deletion_mark) AND is_visible AND (name_norm ~~ 'сме%'::text) AND (product_count_cache > 0))
                                      Rows Removed by Filter: 92
                                      Buffers: shared read=11
                    ->  Subquery Scan on "*SELECT* 3" (actual time=0.044..0.085 rows=20 loops=1)
                          Buffers: shared hit=20 read=4
                          ->  Limit (actual time=0.044..0.083 rows=20 loops=1)
                                Buffers: shared hit=20 read=4
                                ->  Index Scan using products_name_norm_prefix_idx on products p_1 (actual time=0.043..0.081 rows=20 loops=1)
                                      Index Cond: (((name_norm)::text >= 'сме'::text) AND ((name_norm)::text < 'смж'::text))
                                      Filter: ((name_norm)::text ~~ 'сме%'::text)
                                      Buffers: shared hit=20 read=4
                    ->  Subquery Scan on "*SELECT* 4" (actual time=2.544..2.544 rows=0 loops=1)
                          Buffers: shared hit=2539 read=4
                          ->  Limit (actual time=2.543..2.544 rows=0 loops=1)
                                Buffers: shared hit=2539 read=4
                                ->  Sort (actual time=2.543..2.543 rows=0 loops=1)
                                      Sort Key: p_2.name_norm COLLATE "C"
                                      Sort Method: quicksort  Memory: 25kB
                                      Buffers: shared hit=2539 read=4
                                      ->  Bitmap Heap Scan on products p_2 (actual time=2.539..2.539 rows=0 loops=1)
                                            Recheck Cond: (name_norm ~~ '% сме%'::text)
                                            Rows Removed by Index Recheck: 2950
                                            Filter: ((NOT deletion_mark) AND is_sellable)
                                            Heap Blocks: exact=2517
                                            Buffers: shared hit=2539 read=4
                                            ->  Bitmap Index Scan on products_name_norm_trgm (actual time=0.620..0.620 rows=2950 loops=1)
                                                  Index Cond: (name_norm ~~ '% сме%'::text)
                                                  Buffers: shared hit=22 read=4
Planning:
  Buffers: shared hit=140 read=7
Planning Time: 4.728 ms
Execution Time: 2.945 ms
```

## 7. Выводы и риски

1. **NFR-PERF-001 на синтетике 50 000 SKU выполнено.** p95 169.8 мс ≤ 300 мс при `-c 50` без пауз, ошибок нет, все `matchType` ожидаемые. Запас на этом стенде — примерно 1,7×.
2. **Узкое место — CPU одного процесса Node, а не PostgreSQL.** При 50 одновременных запросах event loop загружен примерно на 95 %. Если на целевом сервере p95 окажется выше 300 мс (медленнее CPU, проверка JWT, больше полей в ответе), действовать в таком порядке:
   - (а) исправить двойной глубокий обход `ServerResponse` в `common/logging` (EQ-SRCH-16): −0,4 мс CPU на запрос, по замеру +10 % пропускной способности;
   - (б) запустить pos-api в нескольких процессах (`node:cluster` или реплики за pos-proxy, D-45). Пул БД — 10 соединений на процесс; PostgreSQL здесь не узкое место. Бенчмарк проверяет такую конфигурацию параметром `--workers N`;
   - (в) на клиенте запрашивать меньший `limit` на первой странице поиска (40 → 20): размер ответа и CPU на построение карточек уменьшатся примерно вдвое.
3. **Дорогие ветви D-31.**
   - Частое слово («смеситель», 4 944 совпадения): rank и count считаются по всем совпадениям — 9–14 мс в БД.
   - Фильтры по агрегатам (`inStock`, `priceMin/Max`) и сортировка по цене или остатку: LATERAL по каждому совпадению — 34 мс на 1 729 товаров.

   Если на реальных данных этого окажется мало, можно денормализовать `min_price` и `available_total` в таблицу-срез: обновляет её sync, читает поиск. Это изменение 07 — вопрос владельцу.
4. **Запасной путь «триграммы» без словаря** (`word_similarity` по всем названиям) стоит 57–80 мс. Он выполняется, только если словарь `search_words` не нашёл исправления. Сервис поиска обновляет словарь не реже раза в минуту после изменения `products`. Надёжнее вызывать `refresh_search_words()` из sync/apply сразу после фиксации прогона каталога (передано интегратору).
5. **Локаль БД (EQ-SRCH-01).** При `LC_CTYPE = 'C'` FTS и триграммы по-русски не работают: весь поиск по названию возвращает пустой результат. Прод (`postgres:17`, `en_US.utf8`) это не затрагивает, но локаль нужно закрепить в 16 и проверять при старте. `SearchService` пишет в журнал `search.locale_unsupported`.
6. **Не измерено здесь:**
   - k6 по T-PERF-001 (50 VU с паузами, 10 мин) и смешанный профиль §8 — задача RM-H-004;
   - поиск по реальному каталогу заказчика (Q-040);
   - целевой сервер на Linux;
   - `GET /search/barcode/{value}` под нагрузкой (по составу: штрихкод, карточка, варианты; сценарий сканера T-CAT-012).

## 8. Повтор после ревью

Повтор полного конвейера после исправлений ревью этапа E и закрытия остатков (независимый проверяющий, «Прогон после
закрытия остатков» в `docs/stages/E_test_run.log`). Предыдущая попытка повтора (17:30, отчёт этапа E) не состоялась:
посев оборвался `ECONNRESET` при ~1 ГБ свободного места на D:.

**Условия.** 2026-10-22, 20:08:33 → 20:12:30 (+04:00; `startedAt` 16:08:42 UTC). Тот же стенд §2 (i7-13650HX, 20 логических
ядер, 16 ГБ, Windows 11 Pro 10.0.26200, Node v24.11.1, PostgreSQL 17.10 embedded, `LC_CTYPE en-US`), свободно на D: 7,4 ГБ.
Машина не была занята другими тестами: процессов node/postgres, кроме постороннего `nodejs.exe` (pid 41432, запущен
18.10), не было; до замера закончены все прогоны pos-api и pos-app (последний — `flutter build windows --release`, 20:08:23).
Параметры те же, что в §4: 1 процесс сервера, журнал `info`, 50 соединений, прогрев 10 с, замер 60 с, 20 запросов.

```bash
cd pos-api && export TEMP=D:/optomstroy/.tmp TMP=D:/optomstroy/.tmp
npm run bench:search -- --sku 50000 --duration 60 --warmup 10 --connections 50 \
  --json ../.tmp/frun/search-bench.json --report ../.tmp/frun/search-bench.md
# EXIT=0
```

Данные: посев 125 с (в первом прогоне — 85 с); строк — как в §3 (товаров 50 000, продаваемых 49 502; вариантов 80 281;
штрихкодов 89 573; цен 265 166; остатков 147 668; категорий 93); `sync_errors` 0. `matchType` — 20 из 20 ожидаемых.

| Группа | n | p50, мс | p95, мс | p99, мс | max, мс | p95 на сервере, мс |
|---|---|---|---|---|---|---|
| все | 41 785 | 62.3 | **135.2** | 191.4 | 356.4 | — |
| штрихкод (4) | 8 426 | 51.0 | 84.6 | 114.9 | 170.7 | 82.1 |
| артикул (6) | 12 556 | 54.3 | 91.8 | 111.0 | 203.6 | 88.5 |
| название (10) | 20 803 | 77.1 | 158.1 | 213.8 | 356.4 | 155.2 |

Ошибок 0, не-2xx 0, тайм-аутов 0; 696.4 запросов/с; CPU сервера 1.36 мс на запрос, загрузка event loop 92.2 %.
Худший запрос — по-прежнему `радиатор` с `inStock=true` и `sort=price:asc`: p50 138.9 / p95 252.0 / p99 320.6 / max 356.4 мс
(p99 и max — выше 300 мс; цель NFR-PERF-001 задана по p95). Опечатка «смиситель» (trgm): p95 157.4 мс; раскладка
`cvtcbntkm`: p95 169.3 мс.

**Сравнение с итогом §1:** p50 78.9 → 62.3 мс, p95 169.8 → 135.2 мс, p99 227.8 → 191.4 мс, 553 → 696 запросов/с. Цель
p95 ≤ 300 мс **достигнута** на синтетике и стенде разработчика; ограничения §1 и §7 п. 6 (синтетика, не реальная интеграция,
не целевой Linux-сервер, без JWT) остаются. Разница с первым прогоном — в пределах разброса между прогонами, отмеченного
в §5.1 (15–30 %), причину отдельно не исследовали.
