import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  type CartReader,
  type NotificationsPort,
  type PaymentsPort,
  PortNotBoundError,
} from '../../src/common/ports/index.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { OrderOnecResultsHandler, type OrdersWorkerLog } from '../../src/orders/worker/order-onec-results.handler.js';
import { OrderDependencyNotifier } from '../../src/orders/worker/order-dependency.notifier.js';
import type { BlockedDependent } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { InMemoryNotifications } from '../support/sales-ports.fakes.js';
import type { PosActor } from '../support/pos-fixture.js';
import { onecRefFor, type OrderDto, orderBody, type OrdersHarness, startOrders } from './support/orders-fixture.js';

/**
 * Обработчик результатов outbox заказа (`OrderOnecResultsHandler`; 07 §8.2, ядро §22.1, §23 п. 2) — ветви, которых
 * нет в сквозных сценариях orders-outbox/orders-ops (13 RM-F-009: «создание заказа … — 100 % веток»; ревью
 * F-trace-2): идемпотентные пропуски (чужой агрегат, неверный статус, заказ не найден, повторная доставка),
 * процесс без портов корзины/платежей/уведомлений (pos-worker, FQ-ORD-05) и с непривязанными портами
 * (`PortNotBoundError`), прочие ошибки портов (повторная доставка job), недопустимый переход автомата → `sync_errors`,
 * `dead` чужого агрегата и сбой уведомления, причина отказа без текста 1С. **Тестовые данные**: embedded PostgreSQL 17,
 * синтетический каталог, ScriptedOnecGateway.
 */
describe('OrderOnecResultsHandler: граничные ветви', () => {
  let h: OrdersHarness;
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;
  let qty = 20;

  class RecLog implements OrdersWorkerLog {
    readonly lines: { level: string; msg?: string; obj: object }[] = [];
    info(obj: object, msg?: string) {
      this.lines.push({ level: 'info', obj, msg });
    }
    warn(obj: object, msg?: string) {
      this.lines.push({ level: 'warn', obj, msg });
    }
    error(obj: object, msg?: string) {
      this.lines.push({ level: 'error', obj, msg });
    }
  }

  const unbound = (token: string) => () => Promise.reject(new PortNotBoundError(token));
  const boom = () => Promise.reject(new Error('сбой порта (тест)'));
  const notBoundPorts = {
    notifications: {
      notify: unbound('NOTIFICATIONS'),
      notifyRole: unbound('NOTIFICATIONS'),
    } as unknown as NotificationsPort,
    cart: { restoreFromOrder: unbound('CART_READER') } as unknown as CartReader,
    payments: { voidOpenForOrderCancel: unbound('PAYMENTS') } as unknown as PaymentsPort,
  };

  beforeAll(async () => {
    h = await startOrders({ env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '700' }, modules: [OrdersModule] });
    a = await h.t.actors();
  });
  afterAll(async () => {
    await h?.t.stop();
  });
  beforeEach(() => {
    h.t.onec.reset();
  });

  async function create(actor: PosActor = a.seller): Promise<OrderDto> {
    const [v] = await h.t.saleableVariants(1);
    qty += 1;
    const cart = await h.cart.create(actor, [{ variantId: v.variantId, quantity: String(qty) }]);
    const res = await h.t
      .req('post', '/orders', actor, { idem: true })
      .send(orderBody(cart, { confirmDuplicate: true }));
    expect(res.status, JSON.stringify(res.body)).toBeLessThan(300);
    return res.body as OrderDto;
  }
  const outbox = async (orderId: string, op = 'create') =>
    (
      await h.t.q<{ id: string; status: string }>(
        `SELECT id, status::text AS status FROM onec_outbox WHERE aggregate_id = $1 AND operation = $2`,
        [orderId, op],
      )
    )[0];
  const orderStatus = async (orderId: string) =>
    (await h.t.q<{ status: string }>(`SELECT status::text AS status FROM orders WHERE id = $1`, [orderId]))[0].status;
  const confirmed = (outboxId: string, onecRef: string = randomUUID()) => ({
    outboxId,
    aggregateId: '',
    onecRef,
    onecNumber: null,
    onecStatus: null,
    attempt: 1,
  });
  const failed = (outboxId: string) => ({ outboxId, aggregateId: '', errorCode: 'ONEC_REJECTED', attempt: 1 });

  /** Заказ, чья задача create отклонена 1С (`failed`), но результат ещё не применён к заказу (потеря job). */
  async function rejectedNotApplied(message: string | null): Promise<{ o: OrderDto; outboxId: string }> {
    const o = await create();
    const ob = await outbox(o.id);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'failed', attempts = 1, last_error_code = 'ONEC_REJECTED', last_error = $2,
              onec_response = $3::jsonb, next_attempt_at = NULL WHERE id = $1`,
      [ob.id, 'POS_E_VALIDATION: отказ (тест)', JSON.stringify(message === null ? {} : { message })],
    );
    return { o, outboxId: ob.id };
  }

  it('onConfirmed / onFailed: пропуски — нет строки, чужой агрегат, неверный статус, повторная доставка', async () => {
    const r = h.results;
    expect(await r.onConfirmed(confirmed(randomUUID()))).toBe('skipped');
    expect(await r.onFailed(failed(randomUUID()))).toBe('skipped');
    const o = await create();
    const ob = await outbox(o.id);
    // pending — ни подтверждение, ни отказ не применяются.
    expect(await r.onConfirmed(confirmed(ob.id))).toBe('skipped');
    expect(await r.onFailed(failed(ob.id))).toBe('skipped');
    await h.drain();
    expect((await outbox(o.id)).status).toBe('sent');
    // Повторная доставка подтверждения: onec_ref уже записан.
    expect(await r.onConfirmed(confirmed(ob.id))).toBe('skipped');
    // Строка outbox другого агрегата (платёж) — не заказ.
    const pay = await h.t.q<{ id: string }>(`SELECT id FROM payments WHERE order_id = $1`, [o.id]);
    const foreign = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                sent_at, onec_ref)
       VALUES ('payment', $1::uuid, $1::uuid, 'create', '{}', '\\x00', 'sent', now(), $2) RETURNING id`,
      [pay[0].id, randomUUID()],
    );
    expect(await r.onConfirmed(confirmed(foreign[0].id))).toBe('skipped');
    await h.t.q(`UPDATE onec_outbox SET status = 'failed', sent_at = NULL, onec_ref = NULL WHERE id = $1`, [
      foreign[0].id,
    ]);
    expect(await r.onFailed(failed(foreign[0].id))).toBe('skipped');
    await h.t.q(`DELETE FROM onec_outbox WHERE id = $1`, [foreign[0].id]);
  });

  it('onFailed: отказ 1С по заказу не в submitting / уже связанному — пропуск; отмена без запроса — пропуск', async () => {
    const o = await create();
    await h.drain();
    const ob = await outbox(o.id);
    await h.t.q(`UPDATE onec_outbox SET status = 'failed', last_error_code = 'ONEC_REJECTED' WHERE id = $1`, [ob.id]);
    expect(await h.results.onFailed(failed(ob.id))).toBe('skipped');
    // Строка cancel в failed без запроса отмены у заказа (запрос уже снят) — пропуск.
    const cancel = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                last_error_code)
       VALUES ('order', $1::uuid, $1::uuid, 'cancel', '{}', '\\x00', 'failed', 'ONEC_REJECTED') RETURNING id`,
      [o.id],
    );
    expect(await h.results.onFailed(failed(cancel[0].id))).toBe('skipped');
    // Подтверждение отмены по уже отменённому заказу — пропуск.
    await h.t.q(`UPDATE onec_outbox SET status = 'sent', sent_at = now(), onec_ref = $2 WHERE id = $1`, [
      cancel[0].id,
      onecRefFor(o.id),
    ]);
    await h.t.q(`UPDATE orders SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [o.id]);
    expect(await h.results.onConfirmed(confirmed(cancel[0].id, onecRefFor(o.id)))).toBe('skipped');
  });

  // docs/stages/F_branch_exceptions.md E-2 (RC-7, RR-4): защитная ветвь — проекция отказа 1С вернула переход, отличный
  // от P2 (`cancelled`) и P3 (`submit_failed`), — обработчик ничего не делает с платежами, корзиной и outbox.
  it('E-2: проекция отказа 1С без перехода submit_failed/cancelled — платежи, корзина и outbox не трогаются', async () => {
    const log = new RecLog();
    const restore = vi.fn(() => Promise.resolve(null));
    const voidOpen = vi.fn(() => Promise.resolve());
    const handler = new OrderOnecResultsHandler({
      db: h.t.db,
      notifications: null,
      cart: { restoreFromOrder: restore } as unknown as CartReader,
      payments: { voidOpenForOrderCancel: voidOpen } as unknown as PaymentsPort,
      log,
    });
    (handler as unknown as { projector: { apply: () => Promise<{ to: string }> } }).projector = {
      apply: () => Promise.resolve({ to: 'submitting' }),
    };
    const { o, outboxId } = await rejectedNotApplied('отказ (тест E-2)');
    expect(await handler.onFailed(failed(outboxId))).toBe('applied');
    expect(await orderStatus(o.id)).toBe('submitting');
    expect((await outbox(o.id)).status).toBe('failed');
    expect(restore).not.toHaveBeenCalled();
    expect(voidOpen).not.toHaveBeenCalled();
  });

  // docs/stages/F_branch_exceptions.md E-3 (RC-7, RR-4): строка outbox, которую параллельная транзакция уже перевела в
  // `cancelled` (между чтением без блокировки и `SELECT … FOR UPDATE`), пропускается — повторный переход
  // `cancelled → cancelled` автомат 07 §6.5 запрещает.
  it('E-3: withdrawOutbox — строка, уже отменённая параллельной транзакцией, пропускается без ошибки', async () => {
    const log = new RecLog();
    const handler = new OrderOnecResultsHandler({ db: h.t.db, notifications: null, cart: null, payments: null, log });
    const { o, outboxId } = await rejectedNotApplied('отказ (тест E-3)');
    await h.t.q(`UPDATE onec_outbox SET status = 'cancelled', cancelled_at = $2 WHERE id = $1`, [
      outboxId,
      '2026-10-23T00:00:00Z',
    ]);
    const w = handler as unknown as { withdrawOutbox(tx: unknown, orderId: string, id: string): Promise<void> };
    await h.t.db.transaction((tx) => w.withdrawOutbox(tx, o.id, outboxId));
    const row = await h.t.q<{ status: string; cancelled_at: Date }>(
      `SELECT status::text AS status, cancelled_at FROM onec_outbox WHERE id = $1`,
      [outboxId],
    );
    expect(row[0].status).toBe('cancelled');
    // Строку не обновляли повторно: момент отмены — от «параллельной» транзакции.
    expect(new Date(row[0].cancelled_at).toISOString()).toBe('2026-10-23T00:00:00.000Z');
  });

  it('pos-worker без портов: отказ 1С → submit_failed без восстановления корзины (журнал), уведомлений нет', async () => {
    const log = new RecLog();
    const bare = new OrderOnecResultsHandler({ db: h.t.db, notifications: null, cart: null, payments: null, log });
    const { o, outboxId } = await rejectedNotApplied(null);
    expect(await bare.onFailed(failed(outboxId))).toBe('applied');
    expect(await orderStatus(o.id)).toBe('submit_failed');
    expect(log.lines.some((l) => l.msg?.startsWith('orders.restore_cart.skipped'))).toBe(true);
    // Причина без текста 1С — last_error (humanReason).
    const row = await h.t.q<{ submit_error_message: string }>(`SELECT submit_error_message FROM orders WHERE id = $1`, [
      o.id,
    ]);
    expect(row[0].submit_error_message).toContain('POS_E_VALIDATION');
    // dead без уведомлений: ничего не падает.
    await bare.onDead({ id: outboxId, aggregateType: 'order', aggregateId: o.id, operation: 'create' }, 'тест');
    expect(log.lines.filter((l) => l.level === 'error')).toHaveLength(0);
  });

  it('порты не привязаны (PortNotBoundError): отказ 1С применяется, корзина/платежи/уведомления пропущены', async () => {
    const log = new RecLog();
    const handler = new OrderOnecResultsHandler({ db: h.t.db, ...notBoundPorts, log });
    const { o, outboxId } = await rejectedNotApplied('Недостаточно товара (тест)');
    expect(await handler.onFailed(failed(outboxId))).toBe('applied');
    expect(await orderStatus(o.id)).toBe('submit_failed');
    const row = await h.t.q<{ submit_error_message: string }>(`SELECT submit_error_message FROM orders WHERE id = $1`, [
      o.id,
    ]);
    expect(row[0].submit_error_message).toBe('Недостаточно товара (тест)');
    await handler.onDead({ id: outboxId, aggregateType: 'order', aggregateId: o.id, operation: 'create' }, 'тест');
    expect(log.lines.filter((l) => l.level === 'error')).toHaveLength(0);
  });

  it('прочая ошибка порта — транзакция откатывается и ошибка пробрасывается (повтор job); dead — журнал без падения', async () => {
    const log = new RecLog();
    const failing = new OrderOnecResultsHandler({
      db: h.t.db,
      notifications: { notify: boom, notifyRole: boom },
      cart: { restoreFromOrder: boom } as unknown as CartReader,
      payments: { voidOpenForOrderCancel: boom } as unknown as PaymentsPort,
      log,
    });
    const { o, outboxId } = await rejectedNotApplied(null);
    await expect(failing.onFailed(failed(outboxId))).rejects.toThrow('сбой порта');
    expect(await orderStatus(o.id)).toBe('submitting');
    await failing.onDead({ id: outboxId, aggregateType: 'order', aggregateId: o.id, operation: 'create' }, 'тест');
    expect(log.lines.some((l) => l.msg === 'orders.outbox_dead.notify_failed')).toBe(true);
    // Только корзина падает (платежи и уведомления — непривязаны): ошибка корзины тоже пробрасывается.
    const cartOnly = new OrderOnecResultsHandler({
      db: h.t.db,
      ...notBoundPorts,
      cart: { restoreFromOrder: boom } as unknown as CartReader,
      log,
    });
    await expect(cartOnly.onFailed(failed(outboxId))).rejects.toThrow('сбой порта');
    expect(await orderStatus(o.id)).toBe('submitting');
    // Только уведомления падают — dead: журнал, без исключения; notifyRole падает первым.
    const notifyOnly = new OrderOnecResultsHandler({
      db: h.t.db,
      ...notBoundPorts,
      notifications: { notify: unbound('N'), notifyRole: boom },
      log,
    });
    const before = log.lines.length;
    await notifyOnly.onDead({ id: outboxId, aggregateType: 'order', aggregateId: o.id, operation: 'create' }, 'тест');
    expect(log.lines.length).toBe(before + 1);
    // Уведомление автору падает (notify) — тоже журнал.
    const notifyAuthor = new OrderOnecResultsHandler({
      db: h.t.db,
      ...notBoundPorts,
      notifications: { notify: boom, notifyRole: unbound('N') },
      log,
    });
    await notifyAuthor.onDead({ id: outboxId, aggregateType: 'order', aggregateId: o.id, operation: 'create' }, 'тест');
    expect(log.lines.length).toBe(before + 2);
  });

  it('onDead: чужой агрегат и несуществующий заказ — без уведомлений', async () => {
    const notes = h.t.fakes!.notifications;
    const count = () => notes.of(a.admin.userId).length + notes.of(a.seller.userId).length;
    const before = count();
    await h.results.onDead(
      { id: randomUUID(), aggregateType: 'payment', aggregateId: randomUUID(), operation: 'create' },
      'x',
    );
    await h.results.onDead(
      { id: randomUUID(), aggregateType: 'order', aggregateId: randomUUID(), operation: 'create' },
      'x',
    );
    expect(count()).toBe(before);
  });

  it('недопустимый переход автомата → sync_errors (OTHER), результат error; прочая ошибка БД — проброс', async () => {
    const o = await create();
    await h.drain();
    const ob = await outbox(o.id);
    // Подтверждение отмены (пометка удаления) для закрытого заказа: closed → cancelled недопустим по 07 §6.3 —
    // результат не повторяется бесконечно, а пишется в sync_errors.
    await h.t.q(`UPDATE orders SET status = 'closed', closed_at = now() WHERE id = $1`, [o.id]);
    const cancel = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                sent_at, onec_ref, onec_response)
       VALUES ('order', $1::uuid, $1::uuid, 'cancel', '{}', '\\x00', 'sent', now(), $2, $3::jsonb) RETURNING id`,
      [o.id, onecRefFor(o.id), JSON.stringify({ ref: onecRefFor(o.id), status: 'Закрыт', deletionMark: true })],
    );
    const res = await h.results.onConfirmed(confirmed(cancel[0].id, onecRefFor(o.id)));
    expect(res).toBe('error');
    const errs = await h.t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE outbox_id = $1`, [
      cancel[0].id,
    ]);
    expect(errs.map((e) => e.error_code)).toEqual(['OTHER']);
    expect(await orderStatus(o.id)).toBe('closed');
    expect(ob.status).toBe('sent');
    // Ошибка не домена (неверный uuid в строке) — пробрасывается вызывающему (повтор job).
    await expect(h.results.onConfirmed(confirmed('не-uuid'))).rejects.toThrow();
  });

  it('заказ строки outbox не найден — пропуск; подтверждение create с пометкой удаления → cancelled; неизвестный статус → sync_errors', async () => {
    const ghost = randomUUID();
    const rows = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                sent_at, onec_ref)
       VALUES ('order', $1::uuid, $1::uuid, 'create', '{}', '\\x00', 'sent', now(), $2) RETURNING id`,
      [ghost, randomUUID()],
    );
    expect(await h.results.onConfirmed(confirmed(rows[0].id))).toBe('skipped');
    await h.t.q(`UPDATE onec_outbox SET status = 'failed', sent_at = NULL, onec_ref = NULL WHERE id = $1`, [
      rows[0].id,
    ]);
    expect(await h.results.onFailed(failed(rows[0].id))).toBe('skipped');
    await h.t.q(`DELETE FROM onec_outbox WHERE id = $1`, [rows[0].id]);
    // Ответ 1С на create: документ уже помечен на удаление (ONEC-020) → заказ cancelled, неполученные платежи voided.
    const o1 = await create();
    const ob1 = await outbox(o1.id);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'sent', sent_at = now(), onec_ref = $2, onec_response = $3::jsonb WHERE id = $1`,
      [
        ob1.id,
        onecRefFor(o1.id),
        JSON.stringify({ ref: onecRefFor(o1.id), status: 'НеСогласован', deletionMark: true }),
      ],
    );
    expect(await h.results.onConfirmed(confirmed(ob1.id, onecRefFor(o1.id)))).toBe('applied');
    expect(await orderStatus(o1.id)).toBe('cancelled');
    const pay = await h.t.q<{ status: string }>(`SELECT status::text AS status FROM payments WHERE order_id = $1`, [
      o1.id,
    ]);
    expect(pay.map((p) => p.status)).toEqual(['voided']);
    // Неизвестный статус 1С в ответе create → sync_errors (ONEC-021), статус по правилам проекции.
    const o2 = await create();
    const ob2 = await outbox(o2.id);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'sent', sent_at = now(), onec_ref = $2, onec_response = $3::jsonb WHERE id = $1`,
      [ob2.id, onecRefFor(o2.id), JSON.stringify({ ref: onecRefFor(o2.id), status: 'СтатусИзБудущего' })],
    );
    expect(await h.results.onConfirmed(confirmed(ob2.id, onecRefFor(o2.id)))).toBe('applied');
    const errs = await h.t.q<{ message: string }>(`SELECT message FROM sync_errors WHERE outbox_id = $1`, [ob2.id]);
    expect(errs.some((e) => e.message.includes('СтатусИзБудущего'))).toBe(true);
  });

  it('ответ 1С на отмену без пометки — заказ не отменён; сверщик применяет потерянный отказ 1С', async () => {
    const o = await create();
    await h.drain();
    const cancel = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                sent_at, onec_ref, onec_response)
       VALUES ('order', $1::uuid, $1::uuid, 'cancel', '{}', '\\x00', 'sent', now(), $2, $3::jsonb) RETURNING id`,
      [o.id, onecRefFor(o.id), JSON.stringify({ ref: onecRefFor(o.id), status: 'НеСогласован', deletionMark: false })],
    );
    expect(await h.results.onConfirmed(confirmed(cancel[0].id, onecRefFor(o.id)))).toBe('applied');
    expect(await orderStatus(o.id)).not.toBe('cancelled');
    await h.t.q(`DELETE FROM onec_outbox WHERE id = $1`, [cancel[0].id]);
    // Потерянный job отказа: сверщик outbox.reconcile-aggregates применяет failed ONEC_REJECTED у submitting.
    const lost = await rejectedNotApplied('Отказ 1С (тест сверщика)');
    const r = await h.results.reconcile();
    expect(r.failed).toBeGreaterThanOrEqual(1);
    expect(await orderStatus(lost.o.id)).toBe('submit_failed');
  });

  it('сбой порта платежей (не PortNotBoundError) при отказе 1С — проброс, заказ не изменён', async () => {
    const handler = new OrderOnecResultsHandler({
      db: h.t.db,
      notifications: null,
      cart: notBoundPorts.cart,
      payments: { voidOpenForOrderCancel: boom } as unknown as PaymentsPort,
      log: new RecLog(),
    });
    const { o, outboxId } = await rejectedNotApplied(null);
    await expect(handler.onFailed(failed(outboxId))).rejects.toThrow('сбой порта');
    expect(await orderStatus(o.id)).toBe('submitting');
  });

  // RM-F-009 (FIX-F-23): ответ 1С на отмену по заказу без onec_ref (create ещё не подтверждён) — ссылка из ответа.
  it('ответ 1С на отмену, пока create не подтверждён (onec_ref заказа пуст): ссылка из ответа 1С, пометка → cancelled', async () => {
    const o = await create();
    const ref = onecRefFor(o.id);
    const cancel = await h.t.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                sent_at, onec_ref, onec_response)
       VALUES ('order', $1::uuid, $1::uuid, 'cancel', '{}', '\\x00', 'sent', now(), $2, $3::jsonb) RETURNING id`,
      [o.id, ref, JSON.stringify({ ref, status: 'НеСогласован', deletionMark: true })],
    );
    expect(await h.results.onConfirmed(confirmed(cancel[0].id, ref))).toBe('applied');
    expect(await orderStatus(o.id)).toBe('cancelled');
    const row = await h.t.q<{ onec_ref: string | null }>(
      `SELECT onec_ref::text AS onec_ref FROM orders WHERE id = $1`,
      [o.id],
    );
    expect(row[0].onec_ref).toBe(ref);
    expect(await h.t.auditRows('order.cancelled', o.id)).toHaveLength(1);
    await h.t.q(`DELETE FROM onec_outbox WHERE id = $1`, [cancel[0].id]);
  });

  // RM-F-009: сверщик считает только применённые результаты (повторно применённый — skipped/error не считается).
  it('reconcile: результат не applied (skipped / error) не увеличивает счётчики', async () => {
    const lostFailed = await rejectedNotApplied('Отказ 1С (сверщик, не применён)');
    const o = await create();
    const ob = await outbox(o.id);
    await h.t.q(`UPDATE onec_outbox SET status = 'sent', sent_at = now(), onec_ref = $2 WHERE id = $1`, [
      ob.id,
      onecRefFor(o.id),
    ]);
    const handler = new OrderOnecResultsHandler({
      db: h.t.db,
      notifications: null,
      cart: null,
      payments: null,
      log: new RecLog(),
    });
    const c = vi.spyOn(handler, 'onConfirmed').mockResolvedValue('skipped');
    const f = vi.spyOn(handler, 'onFailed').mockResolvedValue('error');
    expect(await handler.reconcile()).toEqual({ confirmed: 0, failed: 0 });
    expect(c).toHaveBeenCalled();
    expect(f.mock.calls.some(([x]) => x.outboxId === lostFailed.outboxId)).toBe(true);
    // Реальное применение — тем же сверщиком (без подмены): оба результата переносятся в заказы.
    c.mockRestore();
    f.mockRestore();
    const r = await handler.reconcile();
    expect(r.confirmed).toBeGreaterThanOrEqual(1);
    expect(r.failed).toBeGreaterThanOrEqual(1);
    expect(await orderStatus(lostFailed.o.id)).toBe('submit_failed');
    expect(await orderStatus(o.id)).not.toBe('submitting');
  });

  it('G-KI-12: заказ ждёт клиента (customer/create в failed/dead/cancelled) — sync_error автору заказа, автору клиента, admin и senior_seller', async () => {
    const o = await create(a.seller);
    const notes = new InMemoryNotifications();
    notes.roleMembers.set('admin', [a.admin.userId]);
    notes.roleMembers.set('senior_seller', [a.senior_seller.userId]);
    await h.t.q(
      `UPDATE customers SET created_by_user_id = $2::uuid WHERE id = (SELECT customer_id FROM orders WHERE id = $1)`,
      [o.id, a.cashier.userId],
    );
    const log = new RecLog();
    const notifier = new OrderDependencyNotifier({ db: h.t.db, notifications: notes, log });
    const changedAt = new Date('2026-10-28T10:00:00Z');
    const item = (
      over: Partial<BlockedDependent> = {},
      dep: Partial<BlockedDependent['dependency']> = {},
    ): BlockedDependent => ({
      id: randomUUID(),
      aggregateType: 'order',
      aggregateId: o.id,
      operation: 'create',
      reason: 'Ожидает элемент customer/create …',
      ...over,
      dependency: {
        id: randomUUID(),
        aggregateType: 'customer',
        aggregateId: randomUUID(),
        operation: 'create',
        status: 'failed',
        lastErrorCode: 'ONEC_REJECTED',
        lastError: '409 POS_E_DUPLICATE: найден другой клиент',
        changedAt,
        ...dep,
      },
    });
    const blocked = item();
    await notifier.onBlocked([blocked]);
    await notifier.onBlocked([blocked]); // повтор — без дублей (dedupe)
    for (const u of [a.seller, a.cashier, a.admin, a.senior_seller]) {
      expect(notes.of(u.userId), u.role ?? '').toHaveLength(1);
    }
    const n = notes.of(a.seller.userId)[0];
    expect(n).toMatchObject({
      kind: 'sync_error',
      severity: 'warning',
      title: `Заказ ${String(o.publicNumber)} ждёт клиента в 1С`,
      payload: { orderId: o.id, outboxId: blocked.id, dependsOnOutboxId: blocked.dependency.id },
      dedupeKey: `outbox_blocked:${blocked.id}:${blocked.dependency.id}:failed:${changedAt.getTime()}`,
    });
    expect(n.body).toContain('1С отклонила создание клиента (409 POS_E_DUPLICATE: найден другой клиент)');
    // dead / cancelled без текста ошибки; автор клиента неизвестен — только автор заказа и роли.
    await h.t.q(
      `UPDATE customers SET created_by_user_id = NULL WHERE id = (SELECT customer_id FROM orders WHERE id = $1)`,
      [o.id],
    );
    await notifier.onBlocked([item({}, { status: 'dead', lastError: null }), item({}, { status: 'cancelled' })]);
    const bodies = notes.of(a.seller.userId).map((x) => x.body);
    expect(bodies.some((b) => b.includes('карточка клиента не доставлена в 1С (попытки исчерпаны). '))).toBe(true);
    expect(bodies.some((b) => b.includes('отправка клиента в 1С отозвана ('))).toBe(true);
    expect(notes.of(a.cashier.userId)).toHaveLength(1);
    // Не заказ / не create / основание не клиент / заказа нет — пропуск.
    const before = notes.items.length;
    await notifier.onBlocked([
      item({ aggregateType: 'payment' }),
      item({ operation: 'cancel' }),
      item({}, { aggregateType: 'order' }),
      item({ aggregateId: randomUUID() }),
    ]);
    expect(notes.items.length).toBe(before);
    // Без порта уведомлений — ничего; порт не привязан — тихо; сбой порта — журнал, исключение не всплывает.
    await new OrderDependencyNotifier({ db: h.t.db, notifications: null, log }).onBlocked([item()]);
    await new OrderDependencyNotifier({ db: h.t.db, notifications: notBoundPorts.notifications, log }).onBlocked([
      item(),
    ]);
    expect(log.lines).toHaveLength(0);
    await new OrderDependencyNotifier({ db: h.t.db, notifications: { notify: boom, notifyRole: boom }, log }).onBlocked(
      [item()],
    );
    expect(log.lines.map((l) => l.msg)).toEqual(['orders.outbox_blocked.notify_failed']);
  });

  it('SYNC-042: отмена во время sending create, затем 1С отклонила create → cancel cancelled, cancelRequested снят, автору запроса — order_status', async () => {
    const o = await create(a.seller);
    const ob = await outbox(o.id);
    // create захвачен воркером (sending) — отмена ставится зависимой задачей cancel (enqueue_cancel_after_create).
    await h.t.q(
      `UPDATE onec_outbox SET status = 'sending', attempts = 1, lease_until = now() + interval '1 hour',
              next_attempt_at = NULL WHERE id = $1`,
      [ob.id],
    );
    const res = await h.t
      .req('post', `/orders/${o.id}/cancel`, a.seller, { idem: true })
      .send({ reason: 'Клиент передумал', reasonCode: 'customer_refused' });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const cancelRow = async () =>
      (
        await h.t.q<{ id: string; status: string; depends_on_outbox_id: string | null; last_error: string | null }>(
          `SELECT id, status::text AS status, depends_on_outbox_id::text AS depends_on_outbox_id, last_error
             FROM onec_outbox WHERE aggregate_id = $1 AND operation = 'cancel'`,
          [o.id],
        )
      )[0];
    expect(await cancelRow()).toMatchObject({ status: 'pending', depends_on_outbox_id: ob.id });
    // Запрос отмены от другого сотрудника (автор запроса ≠ автор заказа) — ему уведомление о снятии.
    await h.t.q(`UPDATE orders SET cancel_requested_by_user_id = $2::uuid WHERE id = $1`, [o.id, a.cashier.userId]);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'failed', lease_until = NULL, last_error_code = 'ONEC_REJECTED',
              last_error = 'POS_E_STOCK: нет остатка (тест)', onec_response = '{"message":"нет остатка"}'::jsonb
        WHERE id = $1`,
      [ob.id],
    );
    const notes = new InMemoryNotifications();
    const handler = new OrderOnecResultsHandler({
      db: h.t.db,
      notifications: notes,
      cart: null,
      payments: null,
      log: new RecLog(),
    });
    expect(await handler.onFailed(failed(ob.id))).toBe('applied');
    const c = await cancelRow();
    expect(c.status).toBe('cancelled');
    expect(c.last_error).toContain('SYNC-042');
    const ord = await h.t.q<{ status: string; cancel_requested_at: Date | null }>(
      `SELECT status::text AS status, cancel_requested_at FROM orders WHERE id = $1`,
      [o.id],
    );
    expect(ord[0]).toMatchObject({ status: 'submit_failed', cancel_requested_at: null });
    const mine = notes.of(a.cashier.userId).filter((n) => n.dedupeKey === `order_cancel_withdrawn:${o.id}:${c.id}`);
    expect(mine).toHaveLength(1);
    expect(mine[0]).toMatchObject({ kind: 'order_status', severity: 'warning' });
    // Повторная доставка job — пропуск, без новых уведомлений и переходов.
    const before = notes.items.length;
    expect(await handler.onFailed(failed(ob.id))).toBe('skipped');
    expect(notes.items.length).toBe(before);

    // Запрос отмены уже снят (cancelRequested=false), а зависимая задача cancel осталась — она отзывается, заказ не
    // трогается повторно, уведомления о снятии нет.
    const o2 = await create(a.seller);
    const ob2 = await outbox(o2.id);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'sending', attempts = 1, lease_until = now() + interval '1 hour',
              next_attempt_at = NULL WHERE id = $1`,
      [ob2.id],
    );
    const res2 = await h.t
      .req('post', `/orders/${o2.id}/cancel`, a.seller, { idem: true })
      .send({ reason: 'Клиент передумал', reasonCode: 'customer_refused' });
    expect(res2.status, JSON.stringify(res2.body)).toBe(200);
    await h.t.q(`UPDATE orders SET cancel_requested_at = NULL WHERE id = $1`, [o2.id]);
    await h.t.q(
      `UPDATE onec_outbox SET status = 'failed', lease_until = NULL, last_error_code = 'ONEC_REJECTED',
              last_error = 'POS_E_STOCK: нет остатка (тест)' WHERE id = $1`,
      [ob2.id],
    );
    expect(await handler.onFailed(failed(ob2.id))).toBe('applied');
    expect((await outbox(o2.id, 'cancel')).status).toBe('cancelled');
    expect(notes.items.some((n) => n.dedupeKey.startsWith(`order_cancel_withdrawn:${o2.id}:`))).toBe(false);
  });

  it('журнал проекции: предупреждение без данных пишется с пустым объектом', () => {
    const log = new RecLog();
    const handler = new OrderOnecResultsHandler({ db: h.t.db, notifications: null, cart: null, payments: null, log });
    const projector = (handler as unknown as { projector: { warn: (msg: string, data?: object) => void } }).projector;
    projector.warn('orders.projection.test');
    projector.warn('orders.projection.test2', { a: 1 });
    expect(log.lines).toEqual([
      { level: 'warn', obj: {}, msg: 'orders.projection.test' },
      { level: 'warn', obj: { a: 1 }, msg: 'orders.projection.test2' },
    ]);
  });
});
