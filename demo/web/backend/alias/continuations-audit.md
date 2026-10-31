# Аудит фоновых продолжений pos-api в браузерном бэкенде (WP-B2)

Plan §3.4 правило 6 и обязательный пункт критика: найти в скомпилированном `dist` все места, где работа
продолжается без `await` вызывающего, и для каждого записать решение. Решение одно из двух: место укладывается в
окно затихания единицы работы (`alias/work-gate.mjs`) или оборачивается подменой в отдельную единицу.

- Источник: `demo/web/.build/pos-api-dist` (tsc текущего рабочего дерева), 593 файла.
- Ревизия: `site/backend/build.json`.
- Перечень строится скриптом поиска шаблонов `void …`, `.catch(… =>`, `setTimeout`/`setInterval`, `setImmediate`,
  `queueMicrotask`, `process.nextTick`. Для `.catch` скрипт смотрит, начинается ли оператор с `await`/`return`.
  Найдено **109 мест**:
  - `void` — 13;
  - таймеры — 19;
  - `.catch` — 77;
  - `setImmediate`, `queueMicrotask`, `process.nextTick` — 0.
- Каждое место, которое скрипт пометил как фоновое, проверено по коду вручную.

## Как это работает в бэкенде

- **Единица работы.** Запрос моста, обработчик задачи pg-boss, команда панели, сид и перечитывание long-poll
  выполняются по одной. Единица заканчивается, когда её функция завершилась и пул pg-shim «затих»: нет держателя
  замка, ожидающих и операторов в полёте 15 мс подряд, но не дольше 200 мс.
- **Продолжение за пределами окна.** Если продолжение не уложилось в окно, оно идёт параллельно со следующей
  единицей. Для pg-shim его операторы чужие. Чужой `BEGIN` не подсаживается никогда. Обычный оператор ждёт замок;
  подсесть в транзакцию активной единицы он может только по белому списку (`piggyback-allow.json`) или после
  простоя держателя, и тогда подсадка помечается «вне белого списка». Ошибки «savepoint … does not exist» быть не
  может: осиротевшая вложенная транзакция получает `ERR_DEMO_TX_ORPHANED` и в сессию не пишет.
- **Работа по таймеру pos-api.** Это не продолжение запроса, а самостоятельный вход в бэкенд. Если она пишет в БД,
  её оборачивает подмена `runTimerUnit()`.

## Обозначения решений

| Код | Решение |
|---|---|
| **W** | Обёрнуто подменой в отдельную единицу работы |
| **Q** | Фоновое продолжение запроса или задачи: короткая работа с БД, укладывается в окно затихания; если нет — правила чужого оператора pg-shim |
| **R** | Подменено: поведение изменено подменой WP-B2 |
| **S** | Запуск: фоновая регистрация при `createApp`/`WorkerRuntime.start`, до `ready`; только операторы pg-boss под замком |
| **T** | Таймер pos-api с одним оператором pg-boss: единица не нужна, оператор под замком |
| **A** | Не фоновое: `.catch` у ожидаемого промиса (`await …`, промис возвращается или хранится и ожидается), таймаут вокруг ожидаемого вызова |
| **N** | Не на пути исполнения демо: CLI, `worker.js` (свой процесс), транспорт, заменённый подменой, или канал, выключенный конфигом |

## Фоновые места и решения

| Место (`.build/pos-api-dist`) | Что делает | Решение |
|---|---|---|
| `sync/scheduler/sync-scheduler.js:98–99` `setInterval(() => this.apply().catch(…))` | Пересчёт расписаний pg-boss каждые `scheduleRefreshMs` (60 с): настройки и upsert расписаний | **W** — `alias/sync-scheduler.mjs`: `startRefresh` вызывает `apply()` через `runTimerUnit('scheduler.refresh')`. Первый `apply()` из `WorkerRuntime.start` идёт при инициализации, до `ready` |
| `customers/jobs/customers-jobs.bridge.js:59–60` `setInterval(() => this.results.reconcile().catch(…))` | Каждые 5 мин сверяет результаты создания клиентов в 1С (`onec_outbox` × `customers`) и вызывает `onConfirmed`/`onFailed` | **W** — `alias/customer-results.mjs`: `CustomerOnecResultsHandler.reconcile()` через `runTimerUnit('customers.reconcile')`. Вызов изнутри активной единицы (по асинхронному стеку) выполняется на месте |
| `jobs/worker-runtime.js:87–88` `setInterval(() => boss.send(QUEUES.outboxDispatch, {}).catch(…))` | Тикер outbox каждые 10 с: одна вставка задачи pg-boss | **T** — вставка задачи подсаживается только по области (`insert pgboss.job: scope`), иначе ждёт замок. Сама отправка в 1С выполняется задачей `outbox.dispatch`, а это уже единица работы |
| `auth/otp/otp.provider.js:67–71` `const p = this.deliver(…).catch(…); this.inflight.add(p); void p.finally(…)` | Доставка OTP-SMS после ответа `POST /auth/otp/request`: фейковый SMS, запись `sms_outbox` | **Q** — в прогонах укладывается в окно (за запросом OTP сразу идёт verify). Пауза повтора `otp.provider.js:171` (`setTimeout(...).unref()`) срабатывает только при сбое SMS, а фейк не сбоит |
| `catalog/search/search.service.js:129` `void this.refreshWordsIfStale()` (+ `:247`) | Фоновое обновление словаря поиска: `SELECT max(updated_at)… FROM products` и `SELECT refresh_search_words()`; не чаще проверки `wordsCheckedAt` | **Q** — выполняется параллельно с самим поиском в той же единице; транзакции нет |
| `catalog/recent/recent-products.service.js:84` `this.recordView(…).catch(…)` | Отметка просмотра карточки товара (`recent_products`) после ответа | **Q** — короткая запись без транзакции, укладывается в окно |
| `payments/qr/qr-status.service.js:235` `this.cancelAtProvider(…).catch(…)` | Отмена QR в 1С после аннулирования (PAY-052: «не ждёт ответа 1С»): вызов имитатора 1С и запись статуса | **Q** — вызов имитатора в процессе (5 мс) и одна запись. Повтор при сбое подбирает задача опроса QR, а это единица работы |
| `common/settings/settings-reader.js:36` `void this.get(key)` (`peek`) | Фоновое обновление кэша `app_settings` | **Q** — один `SELECT`. Ключ `select app_settings` есть в белом списке (unit/idle): общий промис кэша может ждать транзакция |
| `admin/audit/audit-jobs.bridge.js:61` `void this.boss.start().then(register).catch(…)` | Регистрация обработчиков и расписаний аудита | **S** |
| `customers/jobs/customers-jobs.bridge.js:52`, `:64` | То же для клиентов (и запуск таймера сверки выше) | **S** |
| `payments/jobs/payments-jobs.bridge.js:42`, `:64`, `:70` (`queuesReady`) | То же для платежей; `queuesReady` хранится и ожидается перед публикацией | **S** |
| `returns/onec/returns-jobs.bridge.js:64`, `:88` | То же для возвратов | **S** |
| `cart/cart-jobs.js:174`, `jobs/payments/payments-jobs.js:71` | `.schedule(…).catch(…)` при регистрации | **S** |
| `common/jobs/pg-boss.service.js:34` `void this.start()`, `:65` `void attempt()`, `:61` таймер повтора | Запуск экземпляра pg-boss API с повторами | **S** |

## Таймеры вокруг ожидаемых вызовов и подменённые паузы

| Место | Что | Решение |
|---|---|---|
| `integrations/onec/onec-extension.gateway.js:35` (пауза повтора GET 500 мс × 2ⁿ, до 3 попыток) | Повторы шлюза 1С внутри единицы работы | **R** — `alias/onec-gateway.mjs`: в демо одна попытка (critic «сон шлюза 1С»). Если повторы включить, каждая пауза учитывается (`onecGatewayStats.sleeps`) и пишется в журнал. Прогон «1С недоступна»: 0 пауз, 0 удержаний и 0 ожиданий дольше 3 с |
| `payments/long-poll/payment-status-waiter.js:139` (тик 200 мс до 25 с) | Ожидание статуса long-poll | **R** — `alias/payment-waiter.mjs`: на время ожидания единица отпускается (`releaseWhile`), перечитывание статуса идёт отдельной единицей `poll`. Параллельный `GET /me` отвечает за 6–7 мс |
| `cart/onec-check.service.js:68`, `customers/receivables/receivables-snapshot.service.js:127`, `sync/receivables/receivables-sync.handler.js:63`, `payments/qr/with-timeout.js:19`, `health/health.service.js:57`, `notifications/sms/sms-dlr.controller.js:142` | Таймауты (`AbortController`/`Promise.race`) вокруг ожидаемого вызова 1С, QR, проверки здоровья, DLR | **A** — имитатор 1С отвечает за ~5 мс, и таймер снимается в `finally` |
| `notifications/sms/sms-send.processor.js:18` `defaultSleep` | Пауза повтора отправки SMS внутри задачи `sms.send` | **A**/**N** — повтор только при сбое провайдера; в демо `SMS_PROVIDER=fake` не сбоит |
| `integrations/onec/onec-http-transport.js:88`, `:93` | Таймеры настоящего HTTP-транспорта 1С | **N** — файл заменён `alias/onec-transport.mjs` |
| `integrations/sms/sms-http-transport.js:62` | Таймер HTTP-транспорта SMSPro | **N** — фейковый провайдер, исходящая сеть запрещена (`shims/net-guard.mjs`) |
| `cli/onec_reregister.js:168`, `:171`; `admin/bootstrap/first-admin.cli.js:107`; `worker.js:176–189` | CLI и отдельный процесс pos-worker | **N** — точка входа демо собирает `WorkerRuntime` сама |

## Ожидаемые `.catch` (решение не нужно, **A**)

Ошибка гасится или журналируется, но промис ожидается в том же потоке, поэтому работа входит в единицу:

- аудит: `auth/otp/otp.service.js:353`, `auth/step-up/step-up.service.js:204`, `cart/cart.controller.js:162`;
- откаты и освобождение:
  - `catalog/search/search.service.js:218`;
  - `db/migrator.js:144`, `:155`, `:195`;
  - `jobs/outbox/outbox-dispatcher.js:287`;
  - `sync/apply/catalog-full-load.service.js:259`, `:507`;
  - `sync/apply/onec-changes.service.js:184`;
  - `sync/receivables/receivables-snapshot.writer.js:93`;
  - `common/idempotency/idempotency.interceptor.js:136`;
  - `registration/registration.service.js:132`;
- хуки outbox: `jobs/outbox/outbox-dispatcher.js:130`, `:282`;
- завершение прогонов синхронизации:
  - `jobs/sync/sync-job.processor.js:113`, `:133`, `:141`;
  - `jobs/sync/changes-sync.handler.js:73`;
  - `jobs/sync/sync-jobs.js:28`;
  - `jobs/sync/sync-worker.wiring.js:63` (ожидается в `registry.notify`);
  - `sync/apply/catalog-full-load.service.js:146`, `:157`;
  - `sync/apply/onec-changes.service.js:266`, `:321`, `:332`, `:404`;
  - `sync/api/sync-runs.service.js:155`;
  - `sync/scheduler/sync-run.requester.js:36`, `:41`;
  - `sync/reconcile/count-check.service.js:119`, `:127`, `:134`;
  - `sync/receivables/receivables-sync.handler.js:90`;
  - `sync/alerts/onec-api-compat.js:94`, `:106`;
  - `sync/alerts/onec-auth-pause.js:52`;
- заказы: `orders/order-create.service.js:601`, `orders/order-cancel.service.js:256`, `orders/documents/documents.service.js:128`;
- профиль: `profile/phone-change.service.js:158` (перевод ошибки уникальности внутри ожидаемой транзакции);
- long-poll: `payments/long-poll/payment-status-waiter.js:94`, `:127`;
- элементы `await Promise.all` или кэш, который возвращается вызывающему: `health/health.service.js:35`, `:39`, `:40`;
  `catalog/search/search.service.js:281`;
- `notifications/sms/sms-dlr.controller.js:135` (ожидается через `Promise.race` с бюджетом);
- фото: `sync/images/image-directory-import.js:65`, `sync/images/image-sync.service.js:86`, `sync/images/image-store.js:84`,
  `sync/images/images-gc.service.js:43`, `:114`;
- остановка: `common/jobs/pg-boss.service.js:60`, `:89`; `jobs/worker-runtime.js:105`; `admin/audit/audit-chain.verifier.js:124`;
  `admin/bootstrap/first-admin.cli.js:66`.

## Вне `dist`

- **pg-boss 12.38** (`node_modules`): опрос очередей (`pollingIntervalSeconds: 2`), надзор, обслуживание и
  расписания cron — собственные таймеры pg-boss.
  - Это не единицы работы.
  - Операторы идут через `pg-shim.bossStatement`: блоки `BEGIN…COMMIT` не подсаживаются, внутренние операторы
    подсаживаются только в области держателя, вставка задачи — только `scope`.
  - Обработчики `work()` — единицы `job` (`alias/pgboss-shim.mjs`).
- **Argon2id** (`@noble/hashes` 1.8.0): `asyncTick` отдавал управление микрозадачей, и проверка PIN (~0,4 с)
  блокировала цикл событий воркера. В `alias/noble-yield.mjs` уступка стала макрозадачей, и каждая уступка отмечает
  «идёт вычисление». Поэтому транзакция step-up, которая хэширует PIN внутри `db.transaction`, не принимается за
  простаивающую и чужие операторы в неё не подсаживаются.
- **Подписчики событий**:
  - уведомления `LISTEN` (`payments_status` ожидателя, `pg-boss` notifier) только будят ожидание или выборку;
    их работа с БД — единицы (`poll`, `job`) или операторы pg-boss;
  - `boss.on('error' | 'warning')` только пишут журнал.

## Проверка

`node demo/web/backend/test/harness/worker-harness.mjs` прогоняет собранный бандл в `worker_threads`:
- сценарии `run-full.mjs`;
- пачку параллельных запросов;
- отмену запросов в очереди и начатых;
- «1С недоступна»;
- таймер пересчёта расписаний каждые 3 с.

Прогон считает подсадки по ключам и причинам. В строгом режиме проходит, если выполнено всё сразу:
- 0 подсадок вне белого списка;
- 0 ожиданий замка и слота дольше 3 с;
- 0 вложенных `BEGIN` из чужой единицы;
- 0 ERROR шима и сторожа.

Подробности каждой подсадки без асинхронной связи пишутся в `shimStats.piggyDetails`: SQL, единица, стек `BEGIN`
держателя. Новое место из этого перечня, которое начнёт подсаживаться, покажет WP-T1 на более широких сценариях.
