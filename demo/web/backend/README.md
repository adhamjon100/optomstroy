# Браузерный бэкенд веб-демо (сборка)

Настоящий pos-api, скомпилированный `tsc` из текущего рабочего дерева, собирается esbuild в один ESM-бандл
`demo/web/site/backend/backend.js` для module Web Worker. Исходники pos-api не меняются: вся адаптация — подмена
модулей при сборке и шимы Node.

## Запуск

```
node demo/web/backend/build-backend.mjs [--skip-tsc] [--skip-snapshot] [--no-minify] [--update-lock] [--allow-over-budget]
node --test "demo/web/backend/test/*.test.mjs"
```

Перед запуском задать `TEMP`/`TMP` на `D:\optomstroy\.tmp`. Сборка занимает около 45 с: tsc около 6–10 с, снимок БД и фото около 20 с (WP-B4), esbuild около 14 с.

Сборка пишет `backend.js`, `build.json` и `THIRD_PARTY_NOTICES.txt` сначала в `demo/web/.build/staging` и копирует их в `site/` только при чистых проверках (review fixes): сборка с ошибками оставляет в `site/` прежнюю удачную.

Коды выхода:
- 0 — сборка прошла;
- 1 — ошибка сборки или проверки;
- 2 — бандл больше бюджета (6,5 МБ min / 1,5 МБ brotli).

## Что получается

| Путь | Что это |
|---|---|
| `site/backend/backend.js` | бандл: pos-api, шимы, подмены, встроенная vfs |
| `site/backend/pglite/` | PGlite 0.3.16 с LICENSE; из `.js` убрана строка `sourceMappingURL` (review fixes); sha256 оригиналов — `pglite.lock.json` `files`, опубликованных копий — `shipped` |
| `site/backend/vfs/…` | внешние файлы виртуальной fs (шрифты Inter); грузятся при старте воркера |
| `site/backend/build.json` | ревизия: `git rev-parse HEAD`, sha256 `git diff HEAD -- pos-api` (индекс и рабочее дерево; review fixes), размеры, sha256 бандла; `epochKey` и его входы, `appVersion` (WP-B3); снимок: sha данных, таблицы, строки, фото (WP-B4) |
| `site/demo/snapshot/`, `site/images/` | снимок БД (S2) и фото товаров (WP-B4, раздел ниже) |
| `site/THIRD_PARTY_NOTICES.txt` | лицензии сторонних компонентов (по metafile), PGlite и PostgreSQL, Inter, Roboto, SQLite, drift |
| `.build/pos-api-dist/` | вывод tsc (не `pos-api/dist`) |
| `.build/backend-report.json` | отчёт: размеры, владельцы байтов, подмены, проверки |
| `.build/backend-metafile.json` | metafile esbuild |

## Где что лежит

- `alias-map.mjs` — таблицы подмен:
  - `PACKAGE_ALIASES` — пакеты;
  - `DIST_ALIASES` — файлы dist;
  - `IMPORT_ALIASES` — один импорт внутри пакета npm;
  - `SUPPORT_MODULES` — модули без своей строки.

  Новая подмена — строка в таблице и модуль в `alias/`. Если у строки `optional: true`, а файла подмены ещё нет,
  строка пропускается. Сборка проверяет, что подмена файла dist экспортирует все его имена.
- `alias/` — модули подмен (WP-B2), описание ниже. Там же заглушки `sharp.mjs`, `stubs.mjs` (bun) и `missing.cjs`
  (бросает MODULE_NOT_FOUND).
- `shims/shim-map.mjs` — встроенные модули Node и их шимы. Встроенный модуль, которого нет в таблице, — ошибка сборки.
  Шимы написаны на CommonJS (`node-*.cjs`): потребитель CJS делает `require('events')` и ждёт сам конструктор.
- `shims/net-guard.mjs` — запрет исходящей сети. Разрешены только свой origin и `data:`/`blob:`; клиент
  `node:http/https`, `net`, `tls` и `dns` бросает `ERR_DEMO_NO_NETWORK`.
- `vfs/build-vfs.mjs` — виртуальная fs. Точка расширения WP-B3/B4: `vfs/transforms.mjs`, например водяной знак
  в шаблонах PDF.
- `pii-map.json`, `pii/pii-transform.mjs` — замена правдоподобных ФИО, телефонов и ИНН синтетики кассира на явно
  тестовые, со списком запрещённых строк. Тот же файл используют WP-B4 и WP-T1.
- `notices/` — генератор THIRD_PARTY_NOTICES и стандартные тексты лицензий.
- Точка входа и жизненный цикл воркера (WP-B3), подробно — раздел ниже:
  - `backend-entry.mjs` — сообщения страницы, `init`/`ready`/`fatal`/`shutdown`, конец единицы работы;
  - `bridge-server.mjs` — HTTP-мост к express (Nest), отмена, ответ изменяющего запроса после сброса на диск;
  - `demo-config.mjs` — переменные pos-api, параметры данных эпохи, сотрудники, приглашение, служебные учётки;
  - `demo-init.mjs` — выбор хранилища, миграции, demo_meta, восстановление, догоняние;
  - `demo-storage.mjs` — том и сброс на диск (fix round 2): `DemoStorage` (очередь сбросов, поколение тома),
    `IdbVolume` (IndexedDB: снимок под замком сессии, commit без замка), `readFence`;
  - `demo-control.mjs` — команды панели `/__demo/*`;
  - `demo-seed.mjs` — история заказов при первом запуске эпохи;
  - `demo-overlay.mjs` — имитатор 1С: состояние в demo_meta, external-ids, режимы `/check`, неплатёжный QR, водяной
    знак PDF;
  - `lib/epoch.mjs` — ключ эпохи (`build.json` `epochKey`).

## Служебные спецификаторы (только в коде `backend/`)

| Спецификатор | Куда ведёт |
|---|---|
| `nm:<путь>` | файл `pos-api/node_modules/<путь>` напрямую, мимо подмен и `exports` |
| `@pos-api-dist/<путь>` | `.build/pos-api-dist/<путь>`, с подменами из `DIST_ALIASES` |
| `@pos-api-scripts/<файл>` | `pos-api/scripts/<файл>` (например, `pos_fake_onec.ts`) |
| `pos-vfs-data` | сгенерированная виртуальная fs |

## Одна сессия PostgreSQL: единица работы и подсадка (WP-B2)

PGlite — одно соединение. Как бэкенд с этим живёт (plan §3.4, правила 1–6):

| Модуль | Что делает |
|---|---|
| `alias/work-gate.mjs` | «Единица работы»: запрос моста (`http`), команда панели (`panel`), обработчик задачи pg-boss (`job`), сид (`seed`), перечитывание long-poll (`poll`) — по одной. Очередь с приоритетами `resume` → `app` → `panel` → `job` → `seed` и старением. Окно затихания пула 15 мс (≤ 200 мс). Отмена: не начатая единица снимается из очереди, начатая получает сигнал и через 250 мс отсоединяется. `releaseWhile` отпускает слот на время ожидания; единица с открытой транзакцией слот не отпускает. Сторож: ожидание слота запросом приложения или панели дольше 3 с (задачей pg-boss или сидом — дольше 15 с) и удержание слота дольше 3 с — ERROR; удержание дольше 30 с — слот освобождается. `runTimerUnit` — работа по таймеру pos-api |
| `alias/pg-shim.mjs` | Шим `pg`: замок сессии и подсадка под SAVEPOINT (правила `scope` / `unit` / `idle`, белый список `piggyback-allow.json`). Чужой BEGIN не подсаживается никогда. Осиротевшая вложенная транзакция получает `ERR_DEMO_TX_ORPHANED`, и «savepoint … does not exist» невозможна. Транзакция drizzle, открытая из колбэка транзакции drizzle держателя (рамка `__posDtx_<id>`, например RL-PIN в `POST /auth/unlock`), сразу становится SAVEPOINT по области. Разбор значений — как у node-postgres: pg-types 2.2.0 или `types` запроса drizzle, таблицей-объектом по всем OID (`rawParsers`). Сторож: ожидание замка дольше 3 с — ERROR, дольше 20 с — оператор отклоняется |
| `alias/piggyback-allow.json` | Белый список подсадок: ключ «глагол таблица» и режимы. У каждой записи где и почему, по прогону. Сборка проверяет формат |
| `alias/pgboss-shim.mjs` | pg-boss 12.38 на `fromPglite` под замком; обработчики `work()` — единицы `job`; `afterNextJob(queue, fn)` — один раз после завершения следующей задачи очереди (догоняние ставит receivables после customers) |
| `alias/payment-waiter.mjs` | long-poll `GET /payments/{id}?wait=N` отпускает единицу на время ожидания |
| `alias/onec-gateway.mjs` | шлюз 1С: одна попытка GET (паузы повторов держали бы единицу секундами при «1С недоступна») |
| `alias/onec-transport.mjs` | транспорт 1С → `PosFakeOnec.handle()` в процессе (отмена, таймаут) |
| `alias/sync-scheduler.mjs`, `alias/customer-results.mjs` | пересчёт расписаний (60 с) и сверка клиентов (5 мин) по таймеру — отдельными единицами |
| `alias/noble-yield.mjs` | Argon2 (`@noble/hashes`) уступает цикл событий макрозадачей и отмечает «идёт вычисление» |
| `alias/jwt-keys.mjs`, `alias/argon2.mjs`, `alias/pino.mjs`, `alias/nestjs-pino.mjs` | ключ JWT эпохи из WebCrypto, Argon2id на чистом JS, журнал в кольцевой буфер |
| `alias/continuations-audit.md` | аудит фоновых продолжений dist (109 мест) и решение по каждому |

Счётчики для `/__demo/state` (WP-B3) и тестов:
- `gateSnapshot()` из `work-gate.mjs`;
- `shimSnapshot()` из `pg-shim.mjs`: подсадки по ключам и причинам, `piggyDetails`, ожидания, сторож;
- `waiterStats`, `onecGatewayStats`.

Тесты и прогон собранного бандла:

```
node --test "demo/web/backend/test/*.test.mjs"
node demo/web/backend/test/harness/worker-harness.mjs [--sku 120] [--no-strict] [--refresh-ms 3000] [--json <файл>] [--quiet]
```

`test/harness/worker-harness.mjs` запускает собранный `site/backend/backend.js` в `worker_threads`. Прослойка
`self`/`postMessage`/`addEventListener` (`worker-boot.mjs`) и хранилище `memory`, протокол моста как у страницы.
- `startWorkerBackend()` — API для WP-T1;
- CLI — сценарии `run-full.mjs` (`scenario-run-full.mjs`) и проверка приёмки WP-B2; код выхода 0, если всё выполнено.

## Воркер: жизненный цикл, протокол, панель (WP-B3)

Порядок `init` (страница → воркер, поля верхнего уровня как у WP-S1; `opts` — для тестов):

1. Хранилище: OPFS (`opfs-ahp`) → IndexedDB → память по `storage` и `storageFallback`. Занятые другой вкладкой файлы
   OPFS — повтор около 10 с, затем `fatal {code: 'storage_busy'}`. Проверяется `state.txt`, а если он был занят в этом
   запуске или менялся меньше 2 мин назад — все файлы `data/` (~1,1 с на 2800 файлов): уходящая вкладка отпускает
   дескрипторы не сразу. Если файл всё же занят при `PGlite.create`, сразу `storage_busy` вместо зависания
   (`createOnOpfsGuarded`; `timings.opfsProbe` в `ready`).
2. Настоящий мигратор pos-api — и на тёплом старте. Новые миграции применяются к данным заказчика; изменённая
   применённая миграция — `fatal {code: 'epoch_incompatible'}`.
3. Холодный старт: seeds, `demo_meta`, секреты эпохи (OTP HMAC, PIN pepper, токен 1С HS), ключ JWT (WebCrypto),
   сотрудники 901/906/907/909, служебные учётки сида 981/986/987 «Демо-история …», каталог настоящим конвейером.
   Шаги идемпотентны: оборванная холодная инициализация доделывается.
4. Каждый старт: приглашение 902 создаётся или продлевается. До `WorkerRuntime.start` — восстановление после падения:
   active-задачи pg-boss → retry, прогоны `sync_runs` running/queued → failed, аренда outbox снята.
5. Имитатор 1С: `PosFakeOnec` + журнал синтетики кассира; состояние из `demo_meta` и сверка с PGlite (номера 1С и
   номер сообщения продолжаются, заказы с номером 1С и ожидающие QR заводятся заново).
6. `createApp` без `listen`, `WorkerRuntime` (срезы stock/prices — тот же синтетический каталог).
7. После `ready`: догоняние — задачи stock, prices, receivables, order_status, images, `onec.changes`, customers,
   `outbox.dispatch`; сид истории в фоне (единицы `seed`).

Сохранность:
- в конце каждой единицы работы состояние имитатора 1С пишется в `demo_meta` (если менялось) — в слоте единицы;
- изменяющая единица (не GET/HEAD/OPTIONS, команда панели, шаг сида) сбрасывает том на диск, и только потом мост шлёт
  ответ. Сброс идёт уже после освобождения слота (`afterRelease` хука конца единицы, fix round 2): следующие запросы
  и задачи не ждут записи на диск. Фоновые изменения сбрасываются не чаще чем раз в 10 с (IndexedDB) или 2 с (OPFS);
- IndexedDB (`demo-storage.mjs` `IdbVolume`, fix round 2): под замком сессии — только синхронный снимок (обход файлов
  MEMFS, сравнение mtime с индексом записанного, `put`/`delete` изменённого в одну транзакцию; `put` клонирует
  сразу) — миллисекунды; commit IndexedDB ждёт только сам сброс. Раньше весь `IDBFS.syncfs` (чтение списка, запись,
  commit) шёл под замком, и медленный commit (3–4,5 с под нагрузкой на диск) останавливал опросы pg-boss и запросы
  (сторож browser soak WP-T1). Сбросы идут по очереди, ещё не начатые объединяются; сбой commit обнуляет индекс, и
  следующий сброс сверяется с IndexedDB заново. Ещё: после снимка — следующая миллисекунда Date.now() (запись в ту же
  мс не теряется), `FS.truncate` ставит mtime (укороченный без записи файл раньше не попадал в IndexedDB). OPFS пишет
  файлы сразу, его `syncToFs` — по-прежнему под замком (1–2 мс);
- перед каждой записью сверяется поколение тома (IndexedDB `optomstroy-demo-fence`, только чтение): чужое поколение —
  записи нет, странице уходит `fenced`, фоновые задачи останавливаются.
- только тесты: `init.testFlushCommitDelayMs` (страница — `?initExtra=` на 127.0.0.1) — «медленный диск», после
  каждого commit IndexedDB воркер ждёт столько мс.

Проверка (Node, `worker_threads`, storage `memory`; «перезагрузка» — `dump` → новый воркер с `loadDataDir`):

```
node demo/web/backend/test/harness/b3-acceptance.mjs [--sku 500] [--json <файл>] [--quiet]
node demo/web/backend/test/harness/worker-harness.mjs          # сценарии WP-B2 на новой точке входа
```

Команды панели (`control {action, args}`): `GET state`, `GET logs`, `POST qr/<paymentId>/pay|expire`,
`POST qr/config`, `POST onec/down`, `POST onec/orders/mode`, `POST onec/check`, `POST orders/<id>/onec-status`,
`POST orders/<id>/ship`, `POST returns/<externalId>/status`, `POST customers/<ref>`, `POST sync/catch-up`,
`POST flush`, `POST reset`; для тестов — `fake`, `config`. Полный протокол и его расширения — `handoff.md`, раздел
«WP-B3 … PROTOCOL CHANGES».

## Снимок БД, фото, ПДн (WP-B4)

`node demo/web/backend/build-backend.mjs` после `tsc` собирает снимок сам (шаг «1б»; `--skip-snapshot` — взять уже
собранный). Отдельно:

```
node demo/web/backend/snapshot/build-snapshot.mjs [--sku 500] [--photos 300] [--no-site] [--s1] [--out <каталог>]
node demo/web/backend/test/harness/b4-acceptance.mjs [--json <файл>] [--quiet] [--skip-determinism] [--skip-s1]
```

После отдельного запуска `build-snapshot.mjs` бандл пересобирать не нужно, если снимок не изменился (он
детерминирован); если изменился — `build-backend.mjs --skip-tsc`, иначе воркер его не примет (sha данных не совпадёт
с `DEMO_BUILD.snapshot`) и загрузит каталог конвейером. `--s1` дополнительно пишет
`.build/snapshot/s1-datadir.tar.gz` (dumpDataDir обычной сборки) — для сравнения в `b4-acceptance.mjs`.

| Путь | Что это |
|---|---|
| `snapshot/build-snapshot.mjs` | сборка снимка и фото, проверки, копия в `site/` |
| `snapshot/builder-entry.mjs` | построитель БД (Node): migrate, seed, сотрудники и «Демо-история …», каталог конвейером, `ImageDirectoryImporter` |
| `snapshot/bundle-builder.mjs` | esbuild для Node теми же подменами, что `backend.js`, но встроенные модули и `sharp` — настоящие |
| `snapshot/det-ids.mjs` | детерминированный UUID v7 вместо `dist/common/ids/uuid.js` — только в построителе |
| `snapshot/export-copy.mjs` | формат S2: выгрузка `COPY … TO '/dev/blob'`, проверка, восстановление (и в воркере) |
| `snapshot/photos.mjs` | синтетические JPEG-заглушки (sharp) |
| `snapshot/forbidden.mjs` | полный список запрещённых строк ПДн из `pii-map.json` и поиск |
| `snapshot/data-steps.mjs` | `ensureUsers` — общий для построителя и `demo-init.mjs` |
| `.build/snapshot/{manifest.json, data.copy, data.copy.gz, images.json, report.json}` | результат; `report.json` — проверки и размеры |
| `.build/images/{sha}/{thumb,card,full}.webp` | фото (их пишет `ImageStore` pos-api) |
| `site/demo/snapshot/{manifest.json, data.copy.gz}`, `site/images/**` | копия для сайта |

Детерминизм: два прогона дают байт-в-байт одинаковые `data.copy`, `data.copy.gz` и `images.json`, а манифест
отличается только `builtAt`.
- Часы БД построителя (`now`, `clock_timestamp`, `transaction_timestamp`, `statement_timestamp`) и `gen_random_uuid`
  берутся из схемы `demo_det`: T0 = 2000-01-01, `clock_timestamp` = T0 + n мкс, UUID v4 из md5(номера).
- pgcrypto заранее ставится в схему `demo_ext`, иначе его `public.gen_random_uuid()` стоял бы в пути поиска раньше.
- JS-идентификаторы pos-api — `det-ids.mjs`; каталог получает `now = T0`.
- В браузере всё время сборки (окно T0 + 24 ч) сдвигается на момент восстановления прямо в тексте COPY. Поэтому в
  снимке нет «запечённой» свежести, и он не стареет.
- Хэш-цепочка аудита (`occurred_at` входит в канон строки) пересчитывается тем же способом, что триггер.
- Таблицы со сроком действия исключены из снимка и при сборке обязаны быть пустыми: приглашения, OTP, сессии,
  устройства, PIN, токены, лимиты, ключи идемпотентности, SMS. Приглашение 902 воркер создаёт на каждом старте.

Восстановление (`demo-init.mjs`, холодный старт эпохи):
1. Параллельно с миграциями — `fetch` `manifest.json` и `data.copy.gz` своего origin, `DecompressionStream`, sha256.
2. Снимок берётся, только если sha данных = `DEMO_BUILD.snapshot.dataSha256` бандла, число SKU совпадает, а миграции,
   dev-миграции и seeds снимка = файлы виртуальной fs.
3. Одна транзакция под замком pg-shim: `session_replication_role = replica`, DELETE строк, которые вставили сами
   миграции (`manifest.migrationRows`), `COPY FROM`, `setval`, пересчёт цепочки аудита, `REFRESH MATERIALIZED VIEW`,
   сверка числа строк.
4. Любая ошибка → ROLLBACK и запасной путь: seeds и каталог конвейером, как в WP-B3, но без фото.

Ключ эпохи (`lib/epoch.mjs`) берёт из манифеста только блок `epoch`: привязку фото «товар → sha», параметры
каталога, сотрудников, формат и T0. Схемы и строк снимка в нём нет: более поздняя миграция меняет снимок, но ключ не
меняет, а к данным зрителя её применяет настоящий мигратор.

Тестовые сообщения воркера: `snapcheck` (число строк таблиц, фото, время данных, приглашение, аудит; только чтение);
`init`: `snapshot: false`, `snapshotData {manifest, dataGz}` (Node: `worker-harness.mjs` передаёт байты
`site/demo/snapshot`), `snapshotAnyBuild`, `snapshotPreloaded` (S1 через `loadDataDir`), `catchUp: false`.

## Тесты демо-бэкенда (WP-T1)

Всё одним запуском (≈ 35 мин с soak 20 мин; нужна собранная `demo/web/site`, TEMP/TMP — `D:\optomstroy\.tmp`):

```
node demo/web/backend/test/run-all.mjs [--soak-min 20] [--no-browser] [--browser chrome|edge] [--skip-soak] [--skip-flush]
```

Сводка — в консоли и в `demo/web/.build/t1/summary.json`; подробности — `.build/t1/{differential,critic,browser-flush,soak,browser-soak}.json`;
несоответствия pos-api контракту, которые есть и у эталона (не блокируют), — `demo/web/.build/contract-report.md`.
Дефекты pos-api вне контракта, которые воспроизводятся и на эталоне (не шимы), ведутся в `test/pos-api-defects.json` и
выводятся в тот же отчёт; в демо они не скрываются (сейчас POSAPI-T1-01: `/sync/status` degraded через час без изменений
сущностей плана обмена — падают critic C4.3b и C4.10b).

Fix round 1 (2026-10-30): разбор типов pg-shim как у node-postgres (дефект 1: 500 на повторе `POST /orders` с тем же
`Idempotency-Key`), вложенная транзакция drizzle без ожидания 1 с (дефект 2, `/auth/unlock`), receivables догоняния после
customers (дефект 3). Дефект 4 — POSAPI-T1-01, см. выше.

Fix round 2 (2026-10-30): сторож browser soak (ожидания замка > 3 с за сбросом IndexedDB) — запись тома IndexedDB
больше не держит ни замок сессии (под ним только снимок), ни слот единицы работы (`afterRelease`); см. «Сохранность».
Новые проверки: `test/storage-idb.test.mjs` (PGlite на IDBFS поверх IndexedDB в памяти `test/support/fake-idb.mjs`) и
шаг run-all «медленный диск» — `browser-soak.mjs --minutes 2 --commit-delay-ms 3500` (`.build/t1/browser-flush.json`,
`--skip-flush` — пропустить). Сводка помечает провалы, совпадающие с известным дефектом pos-api (`knownPosApiDefect`,
`demoFailures`), но код выхода остаётся 1. Дифференциальный тест: расхождение бандл ↔ эталон — артефакт шимов, только
если оно есть и у C↔B и повторяется против второго прогона эталона B2 (запускается лишь при кандидатах); гонки с
фоном («заказ → сразу отмена» против отправки outbox ≈ 2 из 30 на обоих; cron статусов заказов → `rowVersion`) —
`differential.flaky` в отчёте. Проверка отмены в обходе принимает оба исхода контракта (`cancelled` или
`cancelRequested`).

| Файл | Что проверяет |
|---|---|
| `test/shims.test.mjs` | http-шим (заголовки, chunked, отмена, express через шим = через `node:http`), vfs = файлы репозитория, timers, util/path/url/qs/events/stream/string_decoder/zlib |
| `test/pg-shim.test.mjs` | WP-B2 + типы и параметры как у node-postgres, многооператорные, LISTEN/NOTIFY, SQLSTATE, транзакции |
| `test/gate.test.mjs` | единица работы с настоящим pg-boss на PGlite, шаблон long-poll, хук конца единицы, `afterRelease` (сброс после освобождения слота) |
| `test/storage-idb.test.mjs` | том IndexedDB (`demo-storage.mjs`): медленный commit не держит замок, очередь сбросов объединяется, запись в ту же мс после снимка, укорочение файла (ftruncate VACUUM), сбой commit и дозапись, «падение» в любой момент под нагрузкой → PostgreSQL восстанавливается, подтверждённое на месте |
| `test/bundle.test.mjs` | `backend.js`: sha и бюджет, нет `node:*`, metafile, ПДн, машинные пути, лицензии, PGlite по lock, снимок |
| `test/contract.test.mjs` | самопроверка валидатора `test/contract/openapi-validate.mjs` (oneOf/anyOf/discriminator/additionalProperties/maxLength/minItems/строгий режим, Problem и коды) |
| `test/differential.test.mjs` | набор API `test/scenarios/` (README 1–6, негативные ветки, обход 116 операций приложения) на бандле, эталоне `test/harness/native-runner.mjs` и повторно на бандле; OpenAPI; покрытие; бандл ↔ эталон |
| `test/critic.test.mjs` | `test/scenarios/critic.mjs`: перезагрузка посреди работы, обрыв посреди задачи, часы +3/+10 дней, заголовки 0.1.0+1, «1С недоступна», сеть, долги после холодного старта |
| `test/scenarios/soak.mjs`, `test/soak/browser-soak.mjs` | сокращённый soak (Node и Chrome IndexedDB), экстраполяция на 8 часов; `--commit-delay-ms N` — «медленный диск» (ответы изменяющих запросов ждут commit, сторож молчит) |

Эталон (`test/harness/native-runner.mjs` → `.build/reference/backend-native.mjs`): та же точка входа и те же подмены
демо, но встроенные модули Node настоящие (http — `node:http` с FakeSocket для моста, fs — `node:fs` с переводом путей
`/vfs/…`, path — `node:path.posix`), пакеты npm — в сборках для Node; pdfkit — браузерная сборка, как в бандле.
Средства харнесса (`test/harness/worker-boot.mjs`): `boot.clockOffsetMs` (часы воркера и PGlite +N), `boot.netRecorder`
(учёт сетевых вызовов до платформы), сообщение `__mem`; `startWorkerBackend({ backendFile })`, `be.terminate()`.

## Review fixes (2026-10-30)

Что изменилось после ревью (подробно — `.tmp/web_demo/handoff.md`, раздел «Review fixes»):

- **Ответ только после записи на диск.** Конец единицы работы (`alias/work-gate.mjs`) отдаёт мосту итог сброса тома
  (`unit.endResult`), а сбой записи состояния «1С» больше не отменяет сброс. Если изменяющий запрос не дошёл до диска
  (`{error}` — квота, отказ IndexedDB; `{fenced}`), `bridge-server.mjs` отвечает 503 вместо «успеха»: с
  Idempotency-Key (POST/PATCH) и для PUT/DELETE — 503 без `code` (RetryInterceptor приложения повторит тем же ключом),
  POST без ключа — ответ с `x-demo-durability: failed`. Странице — сообщение `storage {ok:false}` (первый сбой
  изменяющего сброса или два фоновых подряд) и `storage {ok:true}` после восстановления; она показывает плашку.
- **Фоновые изменения.** Задача pg-boss, записавшая `payments`, `orders` или `return_requests` (отметка pg-shim
  `noteWrite`), сбрасывается сразу; GET-ответ ждёт идущий изменяющий сброс (`durableIdle`) и сброс своей единицы,
  если она изменила состояние «1С».
- **PGlite погиб после ready** (ловушка WebAssembly, abort, база закрыта не нами): `pg-shim` отмечает аварию,
  воркер шлёт `fatal {code: 'pglite_aborted'}`, запросы — 503 «Сервер демо остановился».
- **Fencing.** Поколение — имя пустой базы `optomstroy-demo-fence-g<поколение>-t<вкладка>` (читается
  `indexedDB.databases()` без транзакций: воркер замороженной вкладки больше не блокирует запись нового поколения на
  ~58 с), сверяются поколение и вкладка, и ещё раз — под замком сессии прямо перед снимком/syncToFs.
- **Сид истории** сохраняет состояние после каждого шага и сразу на диск; Idempotency-Key заказа — до POST /orders:
  F5 посреди шага продолжает тот же заказ; пауза повторной отправки кода (429) пережидается; при выходе вкладки сид
  останавливается, не помечаясь «failed».
- **«Отгрузить»** — только `approved`/`awaiting_shipment` (иначе `STATE` с подсказкой).
- **Сборка:** staging, `git diff HEAD`, PGlite без `sourceMappingURL`, уведомления с разделом 6 (Flutter
  `assets/NOTICES`), точный файл Roboto, пути pub-кэша и Flutter SDK из окружения, ошибка сборки при отсутствии
  источника лицензии.
- **Тесты:** `test/durability.test.mjs` (мост, сбой записи, задачи, «Отгрузить», гибель PGlite, F5 посреди сида),
  fencing в `test/storage-idb.test.mjs`, `test/realpg/realpg-diff.mjs` (набор API на бандле и на настоящем
  PostgreSQL 17 — шаг 3б `run-all.mjs`), `run-all.mjs` — код 3, если все провалы — известные дефекты pos-api.
