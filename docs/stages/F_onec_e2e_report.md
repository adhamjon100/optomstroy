# F — Сквозная проверка заказа в 1С (RM-F-010): **на фикстурах, НЕ выполнено на копии 1С**

**Статус RM-F-010: «не выполнено, блокер для I»** (13 §3.6, критерий 4). Тестовой копии базы 1С нет (RM-A-006,
O-05). HTTP-сервис расширения «OptomstroyPOS» от специалиста 1С не получен (ядро R0 v1.9 §24.3; RM-B-014,
RM-E-016 — статус «API 1С не получен», `docs/stages/E_onec_extension_acceptance.md`). Скриншотов 1С и
идентификаторов документов тестовой базы в этом отчёте **нет и быть не может**.

Всё, что описано ниже как проверенное, проверено на **управляемом фейке HTTP-сервиса расширения 1С**
(`pos-api/scripts/pos_fake_onec.ts`, ответы построены из фикстур `contracts/onec/fixtures`) и на
`FakeOnecGateway`/`ScriptedOnecGateway` в наборах тестов. Это **не реальная интеграция**: данных заказчика нет,
поведение настоящей 1С (проведение, автоскидки, статусы, банковская интеграция QR) не проверено (SRC-D-176, 13 §7.14).

Дата: 2026-10-23. Журнал команд: `docs/stages/F_test_run.log`.

---

## 1. Что проверено на фейке (настоящие процессы)

Команда: `cd pos-api && npm run build && node scripts/local-stack.mjs pos-smoke` (или `npm run test:e2e:pos`).
Стенд: embedded PostgreSQL 17 → `dist/migrate.js --seed` → каталог через `FakeOnecGateway` (200 синтетических SKU +
фикстуры 1С) → отдельный процесс фейка HTTP-сервиса 1С → `node dist/main.js` (pos-api) и `node dist/worker.js`
(pos-worker) с `ONEC_MODE=extension`, `ONEC_BASE_URL` → фейк. То есть заказ уходит в «1С» через **боевой**
HTTP-адаптер `OnecExtensionGateway` (Basic + `X-POS-Client-Key`, `X-Request-Id`, таймауты), канал записи outbox
pos-worker и обработчики результата — как в production. Итог: `pos-smoke итог: 30/30 PASS`.

| Шаг критерия RM-F-010 | Что сделано на фейке | Результат |
|---|---|---|
| 1. Документ содержит внешний UUID заказа | `POST /orders` → outbox `create` → pos-worker → `POST /pos/v1/orders` с `externalId = orders.id`; фейк хранит документ «Заказ клиента» под этим `externalId`, в заказ POS записаны `onec.ref`, `onec.number`, статус спроецирован в момент `sent` (`awaiting_payment`) | PASS |
| 2. Повторная отправка не создаёт дубль | (а) повтор `POST /orders` с тем же `Idempotency-Key` → тот же заказ (`Idempotent-Replayed: true`), второй строки outbox нет; (б) повторный `POST /pos/v1/orders` с тем же `externalId` → `200`, тот же `ref`/номер, документ один; (в) 503 → повтор outbox по графику и dead-letter → ручной повтор `POST /sync/outbox/{id}/retry` — документ создаётся один раз с тем же `externalId` | PASS (идемпотентность фейка по `externalId` — модель требования 05 ONEC-039, а не проверка 1С) |
| 3. Смена статуса в 1С («К выполнению») отражается в `/orders/{id}` ≤ 5 мин | статус документа в фейке → `КВыполнению`; `GET /orders/{id}?refreshFromOnec=true` → `awaiting_shipment`, `onecSyncState=linked`; в pos-worker действует расписание `sync.order_status` (на стенде — каждую минуту, по умолчанию `*/5`) | PASS (на фейке, время — секунды) |
| 4. При отсутствии копии — отчёт «не выполнено, блокер для I» | этот документ | выполнено |
| 5. QR через 1С (`QR_PROVIDER=onec`) | `POST /orders {qr_bakai}` → QR после COMMIT через `POST /pos/v1/payments/qr` фейка (`qr.provider=onec`, `autoConfirm=true`) → pos-worker опрашивает `GET /pos/v1/payments/{externalId}/status` (`payments.qr_onec_poll`) → на 2-м опросе `paid` с той же суммой → платёж `received`, заказ оплачен, товарный чек PDF; при `QR_PROVIDER=none` — статический QR, ручное подтверждение со step-up, обращений к методам QR 1С нет | PASS на фейке; **на копии «QR через 1С не проверен» — действует `QR_PROVIDER=none` до приёмки методов QR (RM-E-016)** |

Дополнительно на том же стенде: отказ 1С `422` → заказ `submit_failed`, корзина восстановлена pos-worker (ORD-027,
порт `CartReader` из контекста Nest воркера), уведомление автору; `503` → заказ `submitting`
(`onecSyncState=pending`, баннер) → восстановление; режим клиента (`allowedPaymentMethods`, `credit` → 403,
заказ `createdVia=customer` → документ 1С).

Наборы тестов на `FakeOnecGateway`/`ScriptedOnecGateway` (in-process, embedded PostgreSQL 17): `npm run test:orders`
(outbox, проекция статусов, `onec-link`, синхронизация статусов, таймаут `/check` → `202`), `npm run test:payments`
(QR через 1С, `amount_mismatch`, `late_payment`, отмена QR, `QR_PROVIDER=none`), `npm run test:onec`
(контракт HTTP-клиента против мока на фикстурах). Результаты — `F_test_run.log`.

## 2. Что не проверено и почему

- Создание документа «Заказ клиента» в настоящей базе УТ 11.5 (реквизиты `Партнер`, `Контрагент`, `Соглашение`,
  `Склад`, `Организация`, проведение, `Статус`), автоскидки 1С, пересчёт сумм (`recalculated`), номера документов.
- Идемпотентность по `externalId` на стороне 1С (ONEC-039, КП-8 «повтор и 10 параллельных»).
- Проекция настоящих статусов УТ (`НеСогласован` / `КВыполнению` / `Закрыт`, `[ТИПОВО: Q-012]`) через `/orders/status`.
- Методы QR 1С (05 §6.7; КП-11…КП-13): банк, формат QR, срок жизни, отмена, уведомление о зачислении (Q-014, O-11).
- Розничный контрагент: `customer.ref = null` для «Розничного покупателя» (FQ-ORD-06) — ожидает `Ref_Key` от 1С.

## 3. Как выполнить RM-F-010 на копии (когда будут копия и API)

Предусловия: тестовая копия УТ 11.5 с установленным расширением по `18_ONEC_API_REQUEST.md`, принятым по RM-E-016
(`docs/stages/E_onec_extension_acceptance.md`), учётные данные HS-публикации (только через `*_FILE`).

1. Приёмка методов (RM-E-016), если ещё не выполнена:
   ```sh
   APP_ENV=staging ONEC_MODE=extension ONEC_BASE_URL=https://<1c-test> ONEC_HS_PATH=<публикация>/hs \
   ONEC_HS_USER_FILE=… ONEC_HS_PASSWORD_FILE=… ONEC_HS_TOKEN_FILE=… \
   npx tsx scripts/onec_acceptance.ts --steps kp1,kp2,kp5,kp18,kp19 --allow-write --out ../docs/stages/E_onec_kp_protocol.md
   ```
2. Стенд POS против копии — тот же композиционный корень, что на фейке: pos-api и pos-worker с
   `ONEC_MODE=extension`, `ONEC_BASE_URL`/`ONEC_HS_PATH` копии, `QR_PROVIDER=onec` только если КП-11…КП-13 приняты,
   иначе `QR_PROVIDER=none`; первичная загрузка каталога — `POST /sync/runs` (full) по сущностям.
3. Шаг 1 (UUID): оформить заказ в приложении (или `POST /api/v1/orders`), дождаться `onecSyncState`/`onec.number`
   в `GET /api/v1/orders/{id}`; в 1С найти «Заказ клиента» по номеру — в реквизите внешнего идентификатора
   (расширение) должен быть `orders.id`. В отчёт: номер, дата, `Ref_Key`, скриншот формы документа.
4. Шаг 2 (без дубля): `POST /api/v1/sync/outbox/{id}/retry` для того же элемента после `failed`/`dead` (или
   повторный `POST /pos/v1/orders` с тем же `externalId` через `scripts/onec_acceptance.ts`, КП-8) → в 1С один
   документ; `GET /pos/v1/external-ids?since=` (КП-19) — одна запись.
5. Шаг 3 (статус ≤ 5 мин): в 1С перевести документ в «К выполнению»; засечь время до смены `status` в
   `GET /api/v1/orders/{id}` без `refreshFromOnec` (расписание `SYNC_ORDER_STATUS_CRON=*/5 * * * *`).
6. Шаг 5 (QR): заказ `qr_bakai` → QR получен из 1С (`qr.provider=onec`); пробный платёж, если банк допускает, →
   `received`; иначе отмена QR (`POST /payments/{id}/void` → `POST /pos/v1/payments/{externalId}/qr/cancel`) и
   статус `expired` по сроку.
7. Сохранить протокол: команды, ответы (без секретов), идентификаторы документов 1С, скриншоты — в этот файл,
   заголовок сменить на «на тестовой копии».

## 4. Ворота G-F

По 13 §3.6 ворота G-F требуют: «RM-F-010 выполнен на копии 1С **или** письменно отложен заказчиком до I с принятием
риска». Копии и API нет, поэтому для прохода G-F нужно **письменное решение заказчика** (владелец — заказчик, O-05,
O-11): отложить RM-F-010 до этапа I и принять риск, что расхождения с настоящей 1С (реквизиты документа, статусы,
автоскидки, QR) будут обнаружены только на копии перед пилотом. До такого решения RM-F-010 — **блокер G-F**, а
отсутствие проверки на копии — **блокер для I** (RM-I-002). Решение заказчика в репозитории не зафиксировано.
