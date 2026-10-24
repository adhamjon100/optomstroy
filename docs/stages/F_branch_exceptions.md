# Этап F — исключения из критерия «100 % ветвей критичных сценариев» (FIX-F-23)

Дата: 2026-10-23 · Основание: 13 §3.6 RM-F-009 («создание заказа, платёж, идемпотентность — 100 % веток»), 12 C-10, T-NFR-004; ревью `docs/reviews/F_review.md` F-trace-2; бэклог `docs/stages/F_spec_sync.md` §3 (FIX-F-23) · Порог проверки — `pos-api/vitest.config.cov-f.ts` (`CRITICAL_BRANCHES`), команда `npm run test:cov:f`.

> **Статус перечня: НЕ УТВЕРЖДЁН владельцем 13.** Перечень составлен исполнителем закрытия этапа F; решение владельца 13 (или независимой проверки RM-F-011) не получено. Бизнес-правила и решения ядра не менялись.

## 1. Итог покрытия ветвей критичных файлов

Измерено прогоном `npm run test:cov:f` 2026-10-23 21:30 (все проекты: unit, e2e, sales-domain, cart, orders, payments, documents, notifications, sms, worker; embedded PostgreSQL 17, тестовые данные; Test Files 73 passed | 2 skipped, Tests 756 passed | 6 skipped; код 0). Источник цифр — `pos-api/coverage/stage-f/coverage-summary.json`.

| Файл | Ветви (покрыто / всего) | Порог (`CRITICAL_BRANCHES`) | Защитные ветви перечня §2 |
|---|---|---|---|
| `src/orders/order-create.service.ts` | 310 / 310 (100 %) | 100 (строки 100) | — |
| `src/cart/checkout.service.ts` (CheckoutPolicy) | 237 / 237 (100 %) | 100 (строки 100) | — |
| `src/payments/app/payments-port.service.ts` | 62 / 62 (100 %) | 100 (строки 100) | — |
| `src/payments/app/payments.service.ts` | 191 / 191 (100 %) | 100 (строки 100) | E-1 (покрыта тестом с подменой) |
| `src/orders/worker/order-onec-results.handler.ts` | 89 / 89 (100 %) | 100 (строки 100) | E-2, E-3 (покрыты тестами с подменой) |
| `src/sales-domain/idempotency/sales-idempotency.ts` | 12 / 12 (100 %) | 100 | — |
| `src/common/idempotency/{fingerprint,idempotency.context,idempotency.interceptor,idempotency.repository,idempotency.service}.ts` | 20/20, 2/2, 48/48, 14/14, 13/13 (100 %) | 100 (строки 100) | — |
| Автоматы: `src/sales-domain/payment/payment-status.ts` (D-21), `order/order-status.ts` (D-20), `cart/cart-status.ts`, `outbox/outbox-status.ts` | 67/67, 94/94, 13/13, 33/33 (100 %) | 100 | — |

Непокрытых ветвей в критичных файлах нет; пороги — 100 % для всех, новая непокрытая ветвь даёт красный `test:cov:f`. Перечень §2 сохранён, потому что три защитные ветви **не достигаются штатным путём** — их покрывают тесты, которые подменяют порт или состояние БД (ревью F, RC-7/RR-4). Владельцу 13 нужно решить, считать ли такое покрытие выполнением RM-F-009 или удалить защитные ветви (§3).

Как достигнуто: наборы `*-branches.spec.ts` на фейках портов и БД (без PostgreSQL) — `test/orders/order-create-branches.spec.ts`, `test/cart/checkout-branches.spec.ts`, `test/payments/payments-service-branches.spec.ts`, `test/payments/payments-port-branches.spec.ts`, `test/sales-domain/automata-branches.spec.ts`, `src/common/idempotency/idempotency-branches.spec.ts`; сценарии на embedded PostgreSQL 17 — дополнения `test/orders/order-onec-results.int.spec.ts`. Мёртвый и избыточный код удалён без изменения поведения: повторная проверка ручной скидки клиента в `CheckoutService.evaluateCheckout` (её выполняют оба вызывающих — `preview` и `validateForCheckout`), запасная ссылка `?? p.onecRef` в `OrderOnecResultsHandler.onConfirmed` (ссылка уже взята из события при разборе ответа), ветвь «ключи равны» в компараторе `canonicalJson` (ключи объекта уникальны).

## 2. Перечень защитных (штатно недостижимых) ветвей (построчно)

| № | Файл:строка | Ветвь | Категория | Обоснование | Как проверено (штатные пути / тест с подменой) |
|---|---|---|---|---|---|
| E-1 | `pos-api/src/payments/app/payments.service.ts:327` (`acceptQr`: `if (isProviderQr(voided)) cancelQr.push(voided.id)`) | `true` | недостижимая (защитная) | В приёме QR-оплаты ветка `void_and_create` возникает, только если открытый платёж другого способа (`planNewPayment`: тот же способ → `reuse`), а `credit` отклоняется раньше (`payment_method_mismatch`). Значит, аннулируется наличный платёж — у него нет референса QR провайдера, `isProviderQr` всегда `false`. Проверка оставлена как защита на случай новых способов оплаты (отмена QR в 1С — SYNC-078). Симметричная ветка в `acceptCash` (строка 237) покрыта | `payments-service-branches.spec`: смена способа с наличного на QR — отмена QR не ставится; `payments-qr-onec.e2e`: смена QR → наличные — отмена QR в 1С; подмена — `payments-service-branches.spec` «E-1: QR — аннулирован открытый QR провайдера» |
| E-2 | `pos-api/src/orders/worker/order-onec-results.handler.ts:168` (`onFailed`: `else if (r.to === 'cancelled')`) | `false` (ни `submit_failed`, ни `cancelled`) | недостижимая (инвариант проекции) | `onFailed` для `create` применяет проекцию с `rejected = true` к заказу `submitting` без `onec_ref` (проверка выше). По таблице 10 §2.2 такой факт даёт только P2 (`cancelled` — деньги получены / подтверждена отмена) или P3 (`submit_failed`); P4…P10 требуют `onec_ref`. Ветка `else` без действий — защита от изменения таблицы проекции | `test/sales-domain/order-status.spec.ts` (исчерпывающая таблица P1…P10); `order-onec-results.int.spec`, `orders-outbox.e2e` — обе достижимые ветви; подмена — `order-onec-results.int.spec` «E-2: проекция отказа 1С без перехода submit_failed/cancelled» |
| E-3 | `pos-api/src/orders/worker/order-onec-results.handler.ts:307` (`withdrawOutbox`: `if (row.status === 'cancelled') continue`) | `true` | гонка (защитная) | Выборка `FOR UPDATE` берёт строку `create` заказа (в той же транзакции перед этим проверено `status = 'failed'`) и строки платежей в статусах `pending/failed/dead`; `cancelled` возможен только если параллельная транзакция отменила строку `create` между чтением (`findOutboxById` без блокировки) и `SELECT … FOR UPDATE`. Повторный переход `cancelled → cancelled` автомат 07 §6.5 запрещает — поэтому строка пропускается | штатно детерминированно не воспроизводится; автомат outbox — `outbox-cart-status.spec` (100 % ветвей); подмена — `order-onec-results.int.spec` «E-3: withdrawOutbox — строка, уже отменённая параллельной транзакцией» |

## 3. Что требуется от владельца 13

1. Утвердить (или отклонить) E-1…E-3 как защитные ветви, покрытые тестами с подменой, в зачёт критерия RM-F-009 «100 % веток» — либо поручить удалить защитные ветви E-1, E-2 (поведение при штатных данных не меняется) и оставить для E-3 тест гонки.
2. После решения сослаться на этот документ в 13 §3.6. Пороги `vitest.config.cov-f.ts` — 100 % при любом решении.
