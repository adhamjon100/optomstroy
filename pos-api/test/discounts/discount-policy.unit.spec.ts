import { describe, expect, it } from 'vitest';
import type { DbExecutor } from '../../src/common/audit/db-executor.js';
import type { SalesActor } from '../../src/common/ports/index.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { bishkekDay, DiscountPolicyService } from '../../src/customers/discounts/discount-policy.service.js';

/**
 * `DiscountPolicyService` — unit на заглушке исполнителя SQL (**тестовые данные**; результаты запросов по очереди):
 * ветви, которых нет в синтетике 1С (условие по категориям, потолок подтверждения и порог причины заданы, карточка
 * без отметки синхронизации и без правил), лимит по нескольким ролям. Сквозные проверки на PostgreSQL —
 * discounts.e2e.spec.ts. 10 DISC-003, DISC-007, DISC-010, DISC-013; 07 §5.33–§5.34.
 */
class QueueDb {
  readonly results: Record<string, unknown>[][] = [];
  execute(): Promise<{ rows: Record<string, unknown>[] }> {
    return Promise.resolve({ rows: this.results.shift() ?? [] });
  }
}

const actor = (roles: string[], isCustomer = false): SalesActor => ({ userId: null, roles, isCustomer });

function make(): { db: QueueDb; svc: DiscountPolicyService } {
  const db = new QueueDb();
  return { db, svc: new DiscountPolicyService(db as unknown as DbExecutor, new PermissionCatalog()) };
}

function limitRow(
  role: string,
  max: string,
  can: boolean,
  approveMax: string | null = null,
  reason: string | null = null,
) {
  return {
    role,
    max_percent: max,
    can_approve_over_limit: can,
    approve_max_percent: approveMax,
    requires_reason_over_percent: reason,
    row_version: 1,
  };
}

function rule(id: string, conditions: Record<string, unknown>) {
  return {
    id,
    source: 'onec',
    name: id,
    kind: 'percent',
    value: '1.00',
    applies_automatically: true,
    is_active: true,
    valid_from: null,
    valid_to: null,
    conditions,
    description_ru: null,
    synced_at: '2026-10-20T00:00:00Z',
  };
}

describe('DiscountPolicyService (unit)', () => {
  it('limits: потолок подтверждения и порог причины нормализуются ("12.5" → "12.50"); не заданы — null', async () => {
    const { db, svc } = make();
    db.results.push([limitRow('admin', '15', true, '20', '12.5'), limitRow('seller', '5.00', false)]);
    expect(await svc.limits(null)).toEqual([
      {
        role: 'admin',
        maxPercent: '15.00',
        canApproveOverLimit: true,
        approveMaxPercent: '20.00',
        requiresReasonOverPercent: '12.50',
        rowVersion: 1,
      },
      {
        role: 'seller',
        maxPercent: '5.00',
        canApproveOverLimit: false,
        approveMaxPercent: null,
        requiresReasonOverPercent: null,
        rowVersion: 1,
      },
    ]);
  });

  it('limitFor: максимум по ролям субъекта; роли без строки не учитываются; режим клиента — 0.00 без запроса', async () => {
    const { db, svc } = make();
    db.results.push([
      limitRow('seller', '5.00', false),
      limitRow('cashier', '7.50', false),
      limitRow('admin', '15.00', true),
    ]);
    expect(await svc.limitFor(null, actor(['seller', 'cashier']))).toBe('7.50');
    db.results.push([limitRow('seller', '5.00', false)]);
    expect(await svc.limitFor(null, actor(['nobody']))).toBe('0.00');
    expect(await svc.limitFor(null, actor(['customer'], true))).toBe('0.00');
    expect(db.results).toHaveLength(0);
  });

  it('canApproveOverLimit: approve_max_percent задан — потолок он (20 %), иначе max_percent; роль без флага — нет', async () => {
    const { db, svc } = make();
    const rows = [limitRow('senior_seller', '10.00', true, '20.00'), limitRow('admin', '15.00', false)];
    db.results.push(rows, rows, rows);
    expect(await svc.canApproveOverLimit(null, actor(['senior_seller']), '20')).toBe(true);
    expect(await svc.canApproveOverLimit(null, actor(['senior_seller']), '20.01')).toBe(false);
    expect(await svc.canApproveOverLimit(null, actor(['admin']), '1')).toBe(false);
  });

  it('activeRules: условие по категориям и minTotal передаются, некорректный customerIds — нет; дата — по Бишкеку', async () => {
    const { db, svc } = make();
    db.results.push([
      {
        ...rule('r1', { categoryIds: ['c1'], minTotal: '10.00', partnerRefs: ['x'], customerIds: 'bad' }),
        source: 'pos',
        valid_to: '2026-12-31',
        description_ru: 'описание',
        synced_at: null,
      },
    ]);
    const [r] = await svc.activeRules(null, new Date('2026-10-23T19:30:00Z'));
    expect(r).toMatchObject({
      id: 'r1',
      source: 'pos',
      conditions: { categoryIds: ['c1'], minTotal: '10.00' },
      validTo: '2026-12-31',
      description: 'описание',
    });
    expect(r?.conditions.customerIds).toBeUndefined();
    expect(bishkekDay(new Date('2026-10-23T19:30:00Z'))).toBe('2026-10-24');
  });

  it('customerTerms: клиента нет → null; без отметки синхронизации и без правил → asOf = момент запроса', async () => {
    const { db, svc } = make();
    db.results.push([]);
    expect(await svc.customerTerms(null, 'x')).toBeNull();
    const on = new Date('2026-10-24T00:00:00Z');
    db.results.push(
      [
        {
          id: 'c1',
          onec_ref: null,
          default_price_list_id: null,
          discount_percent: null,
          credit_allowed: false,
          credit_days: null,
          credit_limit: null,
          synced_at: null,
        },
      ],
      [rule('byRef', { partnerRefs: ['ref-1'] })],
    );
    expect(await svc.customerTerms(null, 'c1', on)).toEqual({
      customerId: 'c1',
      priceListId: null,
      customerDiscountPercent: null,
      rules: [],
      creditAllowed: false,
      paymentTermDays: null,
      creditLimit: null,
      asOf: on,
    });
  });

  it('customerTerms: правила без условия по клиентам и по ref 1С клиента; чужие — нет; asOf — самая поздняя отметка', async () => {
    const { db, svc } = make();
    db.results.push(
      [
        {
          id: 'c2',
          onec_ref: 'ref-2',
          default_price_list_id: 'pl',
          discount_percent: '3',
          credit_allowed: true,
          credit_days: 7,
          credit_limit: '10.00',
          synced_at: '2026-10-21T00:00:00Z',
        },
      ],
      [
        rule('all', {}),
        rule('byRef', { partnerRefs: ['ref-2'] }),
        rule('byId', { customerIds: ['c2'] }),
        rule('other', { partnerRefs: ['ref-9'], customerIds: ['c9'] }),
      ],
    );
    const t2 = await svc.customerTerms(null, 'c2', new Date('2026-10-24T00:00:00Z'));
    expect(t2?.rules.map((r) => r.id)).toEqual(['all', 'byRef', 'byId']);
    expect(t2).toMatchObject({
      priceListId: 'pl',
      customerDiscountPercent: '3.00',
      paymentTermDays: 7,
      creditLimit: '10.00',
      asOf: new Date('2026-10-21T00:00:00Z'),
    });
  });
});
