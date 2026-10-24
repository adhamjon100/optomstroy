import { randomUUID } from 'node:crypto';
import { NOTIFICATIONS_PORT, type NotificationsPort } from '../../src/common/ports/index.js';
import { NotificationsModule } from '../../src/notifications/notifications.module.js';
import { NotificationsPortService } from '../../src/notifications/center/notifications-port.service.js';
import { type OnecOrderStatus, planOrderStatusChange } from '../../src/sales-domain/order/order-status.js';
import { type PosActor, PosTestApp } from '../support/pos-fixture.js';

/**
 * RM-F-008 (D-41; 08 §4.16; 07 §5.50) e2e на стенде pos-fixture (embedded PostgreSQL 17 — **тестовые данные**):
 * `NotificationsPort` (дедупликация, рассылка роли), `GET /notifications` (только свои, `unread`, `kind`, `since`,
 * курсор, `unreadCount`), `POST /notifications/{id}/read`, `POST /notifications/read-all` (идемпотентно), IDOR
 * (чужое → 404), смена статуса заказа из 1С-фейка → уведомление владельцу заказа через порт.
 */
let t: PosTestApp;
let port: NotificationsPort;

beforeAll(async () => {
  t = await new PosTestApp().start({ modules: [NotificationsModule], skuCount: 40 });
  port = t.registry.get(NOTIFICATIONS_PORT);
});

afterAll(async () => {
  await t?.stop();
});

async function seedN(user: PosActor, n: number, kind: 'system' | 'order_status' | 'sync_error' = 'system') {
  const ids: string[] = [];
  for (let i = 0; i < n; i += 1) {
    const r = await port.notify(null, {
      userId: user.userId,
      kind,
      severity: 'info',
      title: `Уведомление ${i + 1}`,
      body: `Текст ${i + 1}`,
      payload: { target: null },
      dedupeKey: `test:${randomUUID()}`,
    });
    ids.push(r.id);
  }
  return ids;
}

describe('NotificationsPort (реализация модуля notifications)', () => {
  it('порт привязан модулем; повтор с тем же dedupeKey не создаёт вторую строку (T-NOTIF-003)', async () => {
    expect(t.registry.isBound(NOTIFICATIONS_PORT)).toBe(true);
    expect(t.registry.get(NOTIFICATIONS_PORT)).toBeInstanceOf(NotificationsPortService);
    const u = await t.actor({ role: 'seller' });
    const input = {
      userId: u.userId,
      kind: 'cart_price_changed' as const,
      severity: 'warning' as const,
      title: 'Цена изменилась',
      body: 'Цена товара в корзине изменилась.',
      payload: { cartId: randomUUID() },
      dedupeKey: 'cart_price_changed:x',
    };
    const first = await port.notify(null, input);
    const second = await port.notify(null, input);
    expect(first.created).toBe(true);
    expect(second).toEqual({ id: first.id, created: false });
    const rows = await t.q<{ c: number }>('SELECT count(*)::int AS c FROM notifications WHERE user_id = $1', [
      u.userId,
    ]);
    expect(rows[0].c).toBe(1);
  });

  it('запись в транзакции вызывающего: откат транзакции — уведомления нет', async () => {
    const u = await t.actor({ role: 'cashier' });
    await expect(
      t.db.transaction(async (tx) => {
        await port.notify(tx, {
          userId: u.userId,
          kind: 'payment_status',
          severity: 'info',
          title: 'Оплата получена',
          body: 'тест',
          dedupeKey: 'payment_status:rollback',
        });
        throw new Error('rollback');
      }),
    ).rejects.toThrow('rollback');
    const rows = await t.q('SELECT 1 FROM notifications WHERE user_id = $1', [u.userId]);
    expect(rows).toHaveLength(0);
  });

  it('notifyRole: всем активным пользователям роли (admin), другим ролям — нет; неизвестный kind — ошибка', async () => {
    const admin1 = await t.actor({ role: 'admin' });
    const admin2 = await t.actor({ role: 'admin' });
    const seller = await t.actor({ role: 'seller' });
    const key = `sync_error:outbox_dead:${randomUUID()}`;
    const ids = await port.notifyRole(null, 'admin', {
      kind: 'sync_error',
      severity: 'error',
      title: 'Документ не передан в 1С',
      body: 'Элемент outbox в dead.',
      payload: { orderId: randomUUID() },
      dedupeKey: key,
    });
    const rows = await t.q<{ user_id: string }>('SELECT user_id FROM notifications WHERE dedupe_key = $1', [key]);
    const users = rows.map((r) => r.user_id);
    expect(users).toEqual(expect.arrayContaining([admin1.userId, admin2.userId]));
    expect(users).not.toContain(seller.userId);
    expect(ids.length).toBe(rows.length);
    const again = await port.notifyRole(null, 'admin', {
      kind: 'sync_error',
      severity: 'error',
      title: 'Документ не передан в 1С',
      body: 'Элемент outbox в dead.',
      dedupeKey: key,
    });
    expect([...again].sort()).toEqual([...ids].sort());
    await expect(
      port.notify(null, {
        userId: seller.userId,
        kind: 'bogus' as never,
        severity: 'info',
        title: 'x',
        body: 'x',
        dedupeKey: 'k',
      }),
    ).rejects.toThrow(/kind/);
  });
});

describe('GET /notifications — свои уведомления, фильтры, курсор, unreadCount', () => {
  // 12: T-NOTIF-001 (GET /notifications: курсор, фильтр kind, unreadCount)
  it('только свои; unreadCount; unread=true; kind; limit/cursor; since; истёкшие скрыты', async () => {
    const me = await t.actor({ role: 'seller' });
    const other = await t.actor({ role: 'seller' });
    await seedN(other, 2);
    const ids = await seedN(me, 5);
    await seedN(me, 1, 'order_status');
    await t.q(
      `INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, dedupe_key, expires_at)
       VALUES ($1, 'system', 'info', 'Истёкшее', 'x', $2, now() - interval '1 minute')`,
      [me.userId, `expired:${randomUUID()}`],
    );

    const all = await t.req('get', '/notifications', me);
    expect(all.status).toBe(200);
    expect(all.headers['cache-control']).toBe('no-store');
    expect(all.body.unreadCount).toBe(6);
    expect(all.body.items).toHaveLength(6);
    expect(all.body.hasMore).toBe(false);
    expect(all.body.nextCursor).toBeNull();
    expect((all.body.items as { title: string }[]).map((n) => n.title)).not.toContain('Истёкшее');
    expect(all.body.items[0]).toMatchObject({ kind: 'order_status', severity: 'info', readAt: null });
    expect(Object.keys(all.body.items[0]).sort()).toEqual(
      ['body', 'createdAt', 'id', 'kind', 'payload', 'readAt', 'severity', 'title'].sort(),
    );

    const kind = await t.req('get', '/notifications?kind=order_status,sync_error', me);
    expect(kind.body.items).toHaveLength(1);
    expect(kind.body.items[0].kind).toBe('order_status');

    // Курсор: 6 уведомлений по 4 → 4 + 2, без повторов и пропусков.
    const p1 = await t.req('get', '/notifications?limit=4', me);
    expect(p1.body.items).toHaveLength(4);
    expect(p1.body.hasMore).toBe(true);
    const p2 = await t.req('get', `/notifications?limit=4&cursor=${encodeURIComponent(p1.body.nextCursor)}`, me);
    expect(p2.body.items).toHaveLength(2);
    expect(p2.body.hasMore).toBe(false);
    const seen = [...p1.body.items, ...p2.body.items].map((n: { id: string }) => n.id);
    expect(new Set(seen).size).toBe(6);
    expect(seen).toEqual((all.body.items as { id: string }[]).map((n) => n.id));

    // Курсор чужого пользователя не раскрывает чужие данные (фильтр user_id в SQL).
    const foreignPage = await t.req(
      'get',
      `/notifications?limit=4&cursor=${encodeURIComponent(p1.body.nextCursor)}`,
      other,
    );
    expect(foreignPage.status).toBe(200);
    expect((foreignPage.body.items as { id: string }[]).every((n) => !seen.includes(n.id))).toBe(true);

    await t.req('post', `/notifications/${ids[0]}/read`, me).expect(200);
    const unread = await t.req('get', '/notifications?unread=true', me);
    expect(unread.body.unreadCount).toBe(5);
    expect((unread.body.items as { id: string }[]).map((n) => n.id)).not.toContain(ids[0]);

    const since = new Date(Date.now() + 60_000).toISOString();
    const none = await t.req('get', `/notifications?since=${encodeURIComponent(since)}`, me);
    expect(none.body.items).toHaveLength(0);
    expect(none.body.unreadCount).toBe(5);
  });

  it('VALIDATION_FAILED: неизвестный kind, limit > 100, подделанный cursor, неверный since', async () => {
    const me = await t.actor({ role: 'cashier' });
    for (const [q, field] of [
      ['kind=bogus', 'kind'],
      ['limit=101', 'limit'],
      ['limit=0', 'limit'],
      ['cursor=abc.1', 'cursor'],
      ['since=yesterday', 'since'],
      ['unread=maybe', 'unread'],
    ] as const) {
      const r = await t.req('get', `/notifications?${q}`, me);
      expect(r.status, q).toBe(400);
      expect(r.body.code).toBe('VALIDATION_FAILED');
      expect(r.body.errors[0].field).toBe(field);
    }
  });

  it('все роли (в т. ч. customer) читают свои; без токена → 401', async () => {
    for (const role of ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer'] as const) {
      const u = await t.actor({ role });
      await seedN(u, 1);
      const r = await t.req('get', '/notifications', u);
      expect(r.status, role).toBe(200);
      expect(r.body.unreadCount).toBe(1);
    }
    expect((await t.req('get', '/notifications')).status).toBe(401);
  });
});

describe('POST /notifications/{id}/read и /read-all — идемпотентно, чужое → 404', () => {
  // 12: T-NOTIF-001 (POST /notifications/{id}/read)
  it('прочитать одно: unreadCount уменьшается, повтор — тот же ответ; чужое и несуществующее → 404', async () => {
    const me = await t.actor({ role: 'seller' });
    const other = await t.actor({ role: 'seller' });
    const [mine1] = await seedN(me, 3);
    const [foreign] = await seedN(other, 1);

    const r1 = await t.req('post', `/notifications/${mine1}/read`, me);
    expect(r1.status).toBe(200);
    expect(r1.body).toEqual({ unreadCount: 2 });
    const [row] = await t.q<{ read_at: Date }>('SELECT read_at FROM notifications WHERE id = $1', [mine1]);
    const r2 = await t.req('post', `/notifications/${mine1}/read`, me);
    expect(r2.status).toBe(200);
    expect(r2.body).toEqual({ unreadCount: 2 });
    const [row2] = await t.q<{ read_at: Date }>('SELECT read_at FROM notifications WHERE id = $1', [mine1]);
    expect(row2.read_at).toEqual(row.read_at);

    const f = await t.req('post', `/notifications/${foreign}/read`, me);
    expect(f.status).toBe(404);
    expect(f.body.code).toBe('NOT_FOUND');
    const [still] = await t.q<{ read_at: Date | null }>('SELECT read_at FROM notifications WHERE id = $1', [foreign]);
    expect(still.read_at).toBeNull();
    expect((await t.req('post', `/notifications/${randomUUID()}/read`, me)).status).toBe(404);
    expect((await t.req('post', '/notifications/not-a-uuid/read', me)).status).toBe(404);
  });

  // 12: T-NOTIF-001 (POST /notifications/read-all)
  it('прочитать все: 200 {unreadCount:0}, повтор (в т. ч. с тем же Idempotency-Key) — тот же ответ; чужие не трогаются', async () => {
    const me = await t.actor({ role: 'cashier' });
    const other = await t.actor({ role: 'cashier' });
    await seedN(me, 4);
    await seedN(other, 2);
    const key = randomUUID();
    const a = await t.req('post', '/notifications/read-all', me, { idem: key });
    expect(a.status).toBe(200);
    expect(a.body).toEqual({ unreadCount: 0 });
    const b = await t.req('post', '/notifications/read-all', me, { idem: key });
    expect(b.status).toBe(200);
    expect(b.body).toEqual({ unreadCount: 0 });
    const c = await t.req('post', '/notifications/read-all', me);
    expect(c.status).toBe(200);
    expect(c.body).toEqual({ unreadCount: 0 });
    const o = await t.req('get', '/notifications', other);
    expect(o.body.unreadCount).toBe(2);
    // Новое уведомление после read-all снова непрочитано (бейдж).
    await seedN(me, 1);
    expect((await t.req('get', '/notifications', me)).body.unreadCount).toBe(1);
  });

  // 12: T-NOTIF-001; 08 §4.16.2 «Уточнения» (FQ-NOTIF-04), OpenAPI 1.2.0: параметр before
  it('read-all?before=: отмечаются только уведомления с createdAt <= before; неверный формат → 400', async () => {
    const me = await t.actor({ role: 'seller' });
    const [old1, old2, fresh] = await seedN(me, 3);
    await t.q(`UPDATE notifications SET created_at = now() - interval '2 hours' WHERE id = ANY($1::uuid[])`, [
      [old1, old2],
    ]);
    const before = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const r = await t.req('post', `/notifications/read-all?before=${encodeURIComponent(before)}`, me);
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ unreadCount: 1 });
    const rows = await t.q<{ id: string; read: boolean }>(
      'SELECT id, read_at IS NOT NULL AS read FROM notifications WHERE user_id = $1 ORDER BY created_at',
      [me.userId],
    );
    expect(Object.fromEntries(rows.map((x) => [x.id, x.read]))).toEqual({ [old1]: true, [old2]: true, [fresh]: false });
    const bad = await t.req('post', '/notifications/read-all?before=yesterday', me);
    expect(bad.status).toBe(400);
    expect(bad.body).toMatchObject({ code: 'VALIDATION_FAILED', errors: [{ field: 'before', rule: 'format' }] });
    expect((await t.req('post', '/notifications/read-all', me)).body).toEqual({ unreadCount: 0 });
  });
});

describe('смена статуса заказа из 1С → уведомление владельцу заказа (RM-F-008 п. 1)', () => {
  /**
   * Потребитель статусов 1С — модуль orders (F-be-orders, `orders.onec-status-changed`): он проецирует статус
   * (`planOrderStatusChange`, 10 §2.2) и вызывает `NotificationsPort.notify` для `created_by_user_id`. Здесь — та же
   * последовательность на фейке 1С (`getOrderStatus` → фикстура `orders-status.200`, «КВыполнению») и реальной
   * реализации порта модуля notifications; модуль orders в стенд не подключается (проверяется агентом orders).
   */
  it('«КВыполнению» из 1С (pending_approval → awaiting_shipment, P10): уведомление order_status с payload.orderId только владельцу; повтор события — без дубля', async () => {
    const owner = await t.actor({ role: 'seller' });
    const stranger = await t.actor({ role: 'seller' });
    // Заказ в долг ждёт согласования в 1С («Не согласован» → pending_approval, P9).
    const o = await t.seedOrder({ createdBy: owner, method: 'credit', status: 'pending_approval' });

    const deliver = async () => {
      const res = await t.onec.getOrderStatus(o.orderId);
      const raw = String((res.body as Record<string, unknown>).status);
      const onecStatus: OnecOrderStatus | null =
        raw === 'КВыполнению'
          ? 'to_execute'
          : raw === 'НеСогласован'
            ? 'not_approved'
            : raw === 'Закрыт'
              ? 'closed'
              : null;
      const [row] = await t.q<{ status: string; created_by_user_id: string; public_number: string }>(
        'SELECT status::text, created_by_user_id, public_number FROM orders WHERE id = $1',
        [o.orderId],
      );
      const change = planOrderStatusChange(
        row.status as 'pending_approval',
        {
          creating: false,
          cancelConfirmed: false,
          rejected: false,
          hasOnecRef: true,
          onecStatus,
          hasShipment: false,
          hasReturn: false,
          paymentMethod: 'credit',
          paidAtSet: false,
          hasReceivedMoney: false,
        },
        'onec_sync',
      );
      expect(change).not.toBeNull();
      return port.notify(null, {
        userId: row.created_by_user_id,
        kind: 'order_status',
        severity: 'info',
        title: `Заказ ${row.public_number}: статус изменён`,
        body: `Новый статус: ${change!.to}`,
        payload: { orderId: o.orderId, status: change!.to },
        dedupeKey: `order_status:${o.orderId}:${change!.to}`,
      });
    };

    const first = await deliver();
    expect(first.created).toBe(true);
    expect(t.onec.callsOf('getOrderStatus').length).toBeGreaterThan(0);
    const second = await deliver();
    expect(second).toEqual({ id: first.id, created: false });

    const mine = await t.req('get', '/notifications?kind=order_status', owner);
    expect(mine.body.unreadCount).toBe(1);
    expect(mine.body.items).toHaveLength(1);
    expect(mine.body.items[0]).toMatchObject({
      id: first.id,
      kind: 'order_status',
      payload: { orderId: o.orderId, status: 'awaiting_shipment' },
    });
    const theirs = await t.req('get', '/notifications?kind=order_status', stranger);
    expect(theirs.body.items).toHaveLength(0);
    expect((await t.req('post', `/notifications/${first.id}/read`, stranger)).status).toBe(404);
  });
});
