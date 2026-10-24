import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { formatAuditChainReport, runVerifyAuditChainCli, verifyAuditChain } from '../../src/admin/audit/index.js';
import { AuditAnchorService } from '../../src/common/audit/audit-anchor.service.js';
import { AuditService } from '../../src/common/audit/audit.service.js';
import { AUDIT_QUERY_PORT, type AuditQueryPort } from '../../src/common/ports/index.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { type Actor, AdminTestApp } from './support/admin-app.js';

/** Ответ `GET /admin/audit-logs` (OpenAPI admin_audit_logs_list: Page + items AuditRow). */
const PAGE_OF_AUDIT_ROWS = {
  allOf: [
    { $ref: '#/components/schemas/Page' },
    {
      type: 'object',
      required: ['items'],
      properties: { items: { type: 'array', items: { $ref: '#/components/schemas/AuditRow' } } },
    },
  ],
};

/**
 * RM-G-006 / RM-G-011 (`chainOk`): `GET /admin/audit-logs` (08 §4.18.7; 11 SEC-083; 12 T-ADMIN-005, T-FLOW-040),
 * порт `AuditQueryPort`, системные события аудита миграции 0018 (sync/outbox), проверка хэш-цепочки и якорей
 * (`verifyAuditChain`, `scripts/verify_audit_chain.ts`). Embedded PostgreSQL 17 со всеми миграциями.
 */
const SEED = fileURLToPath(new URL('../../seeds/0001_defaults.sql', import.meta.url));

interface Row {
  id: string;
  action: string;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  chainOk: boolean;
  rowHash: string;
  actor: { id: string; displayName: string; role?: string } | null;
  entityId: string | null;
  result: string;
}

describe('admin/audit: журнал аудита, маскирование, цепочка (RM-G-006)', () => {
  const t = new AdminTestApp();
  let admin: Actor;
  let owner: Actor;
  let cashier: Actor;
  const from = () => new Date(Date.now() - 3600_000).toISOString();
  const to = () => new Date(Date.now() + 3600_000).toISOString();
  const list = (a: Actor | undefined, query: Record<string, string>) =>
    t.req('get', `/admin/audit-logs?${new URLSearchParams({ from: from(), to: to(), ...query }).toString()}`, a);
  const items = (body: unknown) => (body as { items: Row[] }).items;
  const paymentId = randomUUID();
  const orderId = randomUUID();

  beforeAll(async () => {
    await t.start('admin_audit_e2e', { audit: true });
    await t.q(readFileSync(SEED, 'utf8'));
    admin = await t.actor('admin', { fullName: 'Админов Админ' });
    owner = await t.actor('owner');
    cashier = await t.actor('cashier', { fullName: 'Кассирова Анна' });
    const audit = t.app.get(AuditService);
    const ctx = { actorUserId: cashier.userId, actorRole: 'cashier' as const, requestId: 'req-g006' };
    await audit.write(ctx, {
      action: 'payment.voided',
      entityType: 'payment',
      entityId: paymentId,
      before: { status: 'cash_pending', amount: '1500.00' },
      after: { status: 'voided', amount: '1500.00' },
      reason: 'Клиент передумал платить',
      stepUpMethod: 'pin',
    });
    await audit.write(ctx, {
      action: 'order.created',
      entityType: 'order',
      entityId: orderId,
      after: { publicNumber: 'POS-2026-000777', total: '2500.00', paymentMethod: 'cash' },
    });
    await audit.write(ctx, {
      action: 'customer.debt_viewed',
      entityType: 'customer',
      entityId: randomUUID(),
      after: { view: 'summary', balance: '12300.00' },
    });
    await audit.write(
      { actorUserId: admin.userId, actorRole: 'admin' },
      {
        action: 'authz.denied',
        result: 'denied',
        after: { route: 'PUT /admin/users/x/roles', permission: 'users.roles.assign' },
      },
    );
  });

  afterAll(async () => {
    await t.stop();
  });

  it('RBAC: admin и owner → 200 (no-store); seller, cashier, senior_seller, customer → 403; без Bearer → 401', async () => {
    for (const role of ['seller', 'cashier', 'senior_seller', 'customer'] as const) {
      const a = await t.actor(role);
      const r = await list(a, {});
      expect([r.status, r.body.code], role).toEqual([403, 'FORBIDDEN']);
    }
    expect((await list(undefined, {})).status).toBe(401);
    for (const a of [admin, owner]) {
      const r = await list(a, {});
      expect(r.status).toBe(200);
      expect(r.headers['cache-control']).toBe('no-store');
      expect(Object.keys(r.body).sort()).toEqual(['hasMore', 'items', 'nextCursor']);
    }
  });

  it('параметры: from/to обязательны, формат → 400; 367 дней и from > to → 422 date_range; 366 дней → 200', async () => {
    const none = await t.req('get', '/admin/audit-logs', admin);
    expect(none.status).toBe(400);
    expect(none.body.code).toBe('VALIDATION_FAILED');
    expect((none.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`)).toEqual([
      'from:required',
      'to:required',
    ]);
    const bad = await list(admin, { result: 'maybe', limit: '0', actorId: 'x', from: 'вчера' });
    expect(bad.status).toBe(400);
    expect((bad.body.errors as { rule: string }[]).map((e) => e.rule).sort()).toEqual([
      'date_time',
      'enum',
      'range',
      'uuid',
    ]);
    const base = Date.parse('2026-10-24T00:00:00Z');
    const iso = (ms: number) => new Date(ms).toISOString();
    const long = await list(admin, { from: iso(base - 367 * 86_400_000), to: iso(base) });
    expect([long.status, long.body.code, long.body.errors[0].rule]).toEqual([422, 'VALIDATION_FAILED', 'date_range']);
    const inverted = await list(admin, { from: iso(base), to: iso(base - 1000) });
    expect([inverted.status, inverted.body.errors[0].rule]).toEqual([422, 'date_range']);
    expect((await list(admin, { from: iso(base - 366 * 86_400_000), to: iso(base) })).status).toBe(200);
  });

  it('SEC-083: admin — финансовые before/after замаскированы, owner — полностью; actor — UserRef без телефона', async () => {
    const byAdmin = items((await list(admin, { action: 'payment.' })).body);
    expect(byAdmin.map((r) => r.action)).toEqual(['payment.voided']);
    expect(byAdmin[0]).toMatchObject({
      before: { status: '***', amount: '***' },
      after: { status: '***', amount: '***' },
      entityId: paymentId,
      chainOk: true,
      actor: { id: cashier.userId, displayName: 'Кассирова Анна', role: 'cashier' },
      actorRole: 'cashier',
      requestId: 'req-g006',
      stepUpMethod: 'pin',
      reason: 'Клиент передумал платить',
    });
    expect(JSON.stringify(byAdmin[0])).not.toContain('1500.00');
    // Контракт OpenAPI: страница Page<AuditRow> (`chainOk` — ядро §19.2; 13 RM-G-011 п. 4; ревью G-trace-15).
    const page = await list(owner, { limit: '200' });
    expect(validateAgainst(PAGE_OF_AUDIT_ROWS, page.body)).toEqual([]);
    expect((page.body as { items: unknown[] }).items.length).toBeGreaterThan(0);
    for (const row of (page.body as { items: unknown[] }).items) expect(validateAgainst('AuditRow', row)).toEqual([]);
    expect(JSON.stringify(byAdmin[0])).not.toMatch(/\+996/);
    const byOwner = items((await list(owner, { action: 'payment.voided' })).body);
    expect(byOwner[0]?.before).toEqual({ status: 'cash_pending', amount: '1500.00' });
    // Прочие события: у admin маскируются только денежные ключи.
    const order = items((await list(admin, { action: 'order.created' })).body)[0];
    expect(order?.after).toEqual({ publicNumber: 'POS-2026-000777', total: '***', paymentMethod: 'cash' });
    const debt = items((await list(admin, { action: 'customer.debt_viewed' })).body)[0];
    expect(debt?.after).toEqual({ view: '***', balance: '***' });
    expect(items((await list(owner, { action: 'customer.debt_viewed' })).body)[0]?.after).toMatchObject({
      balance: '12300.00',
    });
  });

  it('фильтры: action (префикс/точное), actorId, entityId, entityType, result; чужой entityId → пусто', async () => {
    const byActor = items((await list(owner, { actorId: cashier.userId })).body).map((r) => r.action);
    expect(byActor.sort()).toEqual(['customer.debt_viewed', 'order.created', 'payment.voided']);
    expect(items((await list(owner, { entityId: orderId })).body).map((r) => r.action)).toEqual(['order.created']);
    expect(items((await list(owner, { entityId: 'POS-1' })).body)).toEqual([]);
    expect(items((await list(owner, { entityType: 'payment' })).body).map((r) => r.action)).toEqual(['payment.voided']);
    expect(items((await list(owner, { result: 'denied' })).body).map((r) => r.action)).toContain('authz.denied');
    expect(items((await list(owner, { result: 'denied' })).body).every((r) => r.result === 'denied')).toBe(true);
    expect(items((await list(owner, { action: 'payment' })).body).map((r) => r.action)).toEqual(['payment.voided']);
    expect(items((await list(owner, { action: 'payment.*' })).body).map((r) => r.action)).toEqual(['payment.voided']);
    const badAction = await list(owner, { action: "x'; DROP" });
    expect([badAction.status, badAction.body.errors[0].rule]).toEqual([400, 'pattern']);
  });

  it('каждое чтение пишет audit.viewed (фильтры, число строк); курсор: страницы без пересечений, подделка → 400', async () => {
    const before = (await t.auditRows('audit.viewed')).length;
    const p1 = await list(admin, { limit: '2', action: 'order.' });
    expect(p1.status).toBe(200);
    const viewed = await t.auditRows('audit.viewed');
    expect(viewed.length).toBe(before + 1);
    expect(viewed.at(-1)).toMatchObject({
      actor_user_id: admin.userId,
      level: 'app',
      after: { filters: { action: 'order.' }, rowsReturned: 1 },
    });
    const all = items((await list(owner, { limit: '200' })).body);
    expect(all.length).toBeGreaterThan(5);
    const first = await list(owner, { limit: '3' });
    expect(first.body.hasMore).toBe(true);
    const second = await list(owner, { limit: '3', cursor: first.body.nextCursor });
    const ids = [...items(first.body), ...items(second.body)].map((r) => r.id);
    expect(new Set(ids).size).toBe(6);
    // Новые сверху: страницы идут по убыванию цепочки (свежие audit.viewed в начале).
    expect(items(first.body)[0]?.action).toBe('audit.viewed');
    const forged = await list(owner, { cursor: `${String(first.body.nextCursor).slice(0, -2)}00` });
    expect([forged.status, forged.body.errors[0].rule]).toEqual([400, 'cursor']);
  });

  it('порт AuditQueryPort: forEntity (новые сверху, маска по зрителю), verifyChain — цела', async () => {
    const port = t.app.get<AuditQueryPort>(AUDIT_QUERY_PORT);
    const adminView = { userId: admin.userId, roles: ['admin'], isCustomer: false };
    const rows = await port.forEntity(null, adminView, 'payment', paymentId);
    expect(rows.map((r) => r.action)).toEqual(['payment.voided']);
    expect(rows[0]?.before).toEqual({ status: '***', amount: '***' });
    expect(rows[0]?.chainOk).toBe(true);
    expect(await port.forEntity(null, adminView, 'payment', 'not-uuid')).toEqual([]);
    expect(await port.verifyChain(null)).toMatchObject({ ok: true, brokenAtChainSeq: null });
  });

  it('0018: sync.run.finished/failed, sync.prices.applied / sync.stock.applied, outbox.confirmed/rejected/dead/cancelled', async () => {
    const run = async (entity: string, status: string, counts: Record<string, unknown>) => {
      const id = randomUUID();
      await t.q(
        `INSERT INTO sync_runs (id, entity, mode, "trigger", status, started_at)
         VALUES ($1::uuid, $2::sync_entity, 'incremental', 'schedule', 'running', now())`,
        [id, entity],
      );
      await t.q(
        `UPDATE sync_runs SET status = $2::sync_run_status, finished_at = now(), counts = $3::jsonb WHERE id = $1::uuid`,
        [id, status, JSON.stringify(counts)],
      );
      return id;
    };
    const prices = await run('prices', 'success', { fetched: 10, inserted: 1, updated: 4, markedDeleted: 0 });
    const stock = await run('stock', 'partial', { fetched: 7, inserted: 0, updated: 3, errors: 1 });
    const stockNoop = await run('stock', 'success', { fetched: 7, skipped: 7 });
    const failed = await run('customers', 'failed', {});
    const finished = await t.auditRows('sync.run.finished');
    expect(finished.map((r) => r.entity_id)).toEqual([prices, stock, stockNoop]);
    expect(finished.every((r) => r.level === 'db' && r.result === 'ok')).toBe(true);
    expect((await t.auditRows('sync.run.failed')).map((r) => [r.entity_id, r.result])).toEqual([[failed, 'error']]);
    expect((await t.auditRows('sync.prices.applied')).map((r) => [r.entity_id, r.after?.changed])).toEqual([
      [prices, 5],
    ]);
    expect((await t.auditRows('sync.stock.applied')).map((r) => [r.entity_id, r.after?.changed])).toEqual([[stock, 3]]);
    // повторный UPDATE без смены статуса событий не пишет
    await t.q(`UPDATE sync_runs SET counts = '{"x":1}' WHERE id = $1::uuid`, [prices]);
    expect((await t.auditRows('sync.run.finished')).length).toBe(3);

    const outbox = async (to: string) => {
      const agg = randomUUID();
      const [row] = await t.q<{ id: string }>(
        `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status)
         VALUES ('order', $1::uuid, $1::text, 'create', '{}'::jsonb, '\\x00'::bytea, 'pending') RETURNING id`,
        [agg],
      );
      await t.q(
        `UPDATE onec_outbox SET status = $2::outbox_status, attempts = 3,
                last_error_code = CASE WHEN $2 IN ('failed','dead') THEN 'ONEC_UNAVAILABLE' END WHERE id = $1::uuid`,
        [row.id, to],
      );
      return row.id;
    };
    const ids = {
      'outbox.confirmed': await outbox('confirmed'),
      'outbox.rejected': await outbox('failed'),
      'outbox.dead': await outbox('dead'),
      'outbox.cancelled': await outbox('cancelled'),
    };
    for (const [action, id] of Object.entries(ids)) {
      const rows = await t.auditRows(action, id);
      expect(rows, action).toHaveLength(1);
      expect(rows[0]?.after).toMatchObject({ aggregateType: 'order', operation: 'create', attempts: 3 });
    }
    expect((await t.auditRows('outbox.dead'))[0]?.result).toBe('error');
    // через API: системные события видны, цепочка цела
    const viaApi = items((await list(owner, { action: 'outbox.' })).body);
    expect(viaApi.map((r) => r.action).sort()).toEqual([
      'outbox.cancelled',
      'outbox.confirmed',
      'outbox.dead',
      'outbox.rejected',
    ]);
    expect(viaApi.every((r) => r.chainOk && r.actor === null)).toBe(true);
  });

  it('целостность: verifyAuditChain и CLI проходят; подмена строки → chainOk=false, разрыв относительно якоря', async () => {
    const out: string[] = [];
    const io = { out: (l: string) => out.push(l), err: (l: string) => out.push(`ERR ${l}`) };
    const env = { DATABASE_URL: t.fdb.url };
    expect(await runVerifyAuditChainCli([], env, io)).toBe(0);
    expect(out.join('\n')).toContain('ЦЕПОЧКА ЦЕЛА');
    expect(await runVerifyAuditChainCli(['--bogus'], env, io)).toBe(2);
    expect(await runVerifyAuditChainCli([], {}, io)).toBe(2);

    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Bishkek' }).format(new Date());
    const anchor = await t.app.get(AuditAnchorService).writeDailyAnchor(today);
    expect(anchor?.created).toBe(true);
    // новые строки после якоря
    await t.app.get(AuditService).write(
      { actorUserId: admin.userId, actorRole: 'admin' },
      {
        action: 'report.viewed',
        entityType: 'report',
        after: { name: 'sales-summary' },
      },
    );
    const victim = (await t.auditRows('report.viewed')).at(-1);
    const [vrow] = await t.q<{ id: string; chain_seq: string }>(
      `SELECT id, chain_seq::text AS chain_seq FROM audit_logs WHERE action = 'report.viewed' ORDER BY chain_seq DESC LIMIT 1`,
    );
    expect(victim).toBeDefined();
    const okReport = await verifyAuditChain(t.fdb.pool);
    expect(okReport).toMatchObject({ ok: true, brokenAtChainSeq: null, anchorFailures: [] });
    expect(okReport.lastGoodAnchor?.anchorDate).toBe(today);

    // Подмена суперпользователем (обход триггера append-only) — RM-G-006 п. 2.
    const su = await t.fdb.client();
    try {
      await su.query('ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_immutable');
      await su.query(`UPDATE audit_logs SET after = '{"name":"подмена"}'::jsonb WHERE id = $1::uuid`, [vrow.id]);
      await su.query('ALTER TABLE audit_logs ENABLE TRIGGER trg_audit_logs_immutable');
    } finally {
      await su.end();
    }
    const tampered = items((await list(owner, { limit: '200' })).body);
    const bad = tampered.filter((r) => !r.chainOk);
    expect(bad.map((r) => r.id)).toEqual([vrow.id]);
    const report = await verifyAuditChain(t.fdb.pool);
    expect(report).toMatchObject({ ok: false, brokenAtChainSeq: vrow.chain_seq });
    expect(report.lastGoodAnchor).toEqual({ anchorDate: today, lastChainSeq: String(anchor!.lastChainSeq) });
    expect(BigInt(report.lastGoodAnchor!.lastChainSeq) < BigInt(vrow.chain_seq)).toBe(true);
    const lines = formatAuditChainReport(report).join('\n');
    expect(lines).toContain(`РАЗРЫВ ЦЕПОЧКИ: chain_seq ${vrow.chain_seq}`);
    expect(lines).toContain(`последний целый якорь: ${today}`);
    out.length = 0;
    expect(await runVerifyAuditChainCli(['--json'], env, io)).toBe(1);
    expect(JSON.parse(out[0] ?? '{}')).toMatchObject({ ok: false, brokenAtChainSeq: vrow.chain_seq });
    const port = t.app.get<AuditQueryPort>(AUDIT_QUERY_PORT);
    expect(await port.verifyChain(null)).toMatchObject({ ok: false, brokenAtChainSeq: vrow.chain_seq });

    // Подмена строки якоря → несовпадение якоря.
    const su2 = await t.fdb.client();
    try {
      await su2.query('ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_immutable');
      await su2.query(`UPDATE audit_logs SET row_hash = sha256('x'::bytea) WHERE chain_seq = $1::bigint`, [
        anchor!.lastChainSeq,
      ]);
      await su2.query('ALTER TABLE audit_logs ENABLE TRIGGER trg_audit_logs_immutable');
    } finally {
      await su2.end();
    }
    const r2 = await verifyAuditChain(t.fdb.pool);
    expect(r2.anchorFailures).toEqual([
      { anchorDate: today, lastChainSeq: String(anchor!.lastChainSeq), reason: 'hash_mismatch' },
    ]);
    expect(r2.lastGoodAnchor).toBeNull();
    expect(formatAuditChainReport(r2).join('\n')).toContain('под подозрением вся таблица');
  });
});
