import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { DiscountKind, DiscountSource, RoleCode } from '../../common/enums.js';
import type {
  CustomerDiscountTerms,
  DiscountPolicyPort,
  DiscountRuleView,
  RoleDiscountLimitView,
  SalesActor,
  SalesTx,
} from '../../common/ports/index.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { hundredthsToPercent, normalizePercent, percentToHundredths } from '../../sales-domain/pricing/percent.js';

const BISHKEK_OFFSET_MS = 6 * 3600_000;

/** Дата по Бишкеку `YYYY-MM-DD` (UTC+6, без летнего времени). */
export function bishkekDay(d: Date): string {
  return new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
}

/** Процент строкой → сотые доли; некорректный — `null` (fail-closed у вызывающего). */
function hundredths(p: string): bigint | null {
  try {
    return percentToHundredths(p);
  } catch {
    return null;
  }
}

/** Канонический процент `"5.00"` из `NUMERIC(5,2)` строки БД (CHECK 0…100 — значение всегда корректно). */
function pct(p: string): string {
  return normalizePercent(p);
}

interface RuleRow extends Record<string, unknown> {
  id: string;
  source: DiscountSource;
  name: string;
  kind: DiscountKind;
  value: string;
  applies_automatically: boolean;
  is_active: boolean;
  valid_from: string | null;
  valid_to: string | null;
  /** `NOT NULL DEFAULT '{}'` (07 §5.33). */
  conditions: Record<string, unknown>;
  description_ru: string | null;
  synced_at: Date | string | null;
}

/** Правило из строки `discount_rules` (07 §5.33) → `DiscountRuleView` (08 `DiscountRule`). */
function ruleView(r: RuleRow): DiscountRuleView {
  const c = r.conditions;
  const strings = (v: unknown): string[] | undefined =>
    Array.isArray(v) && v.every((x) => typeof x === 'string') ? v : undefined;
  const categoryIds = strings(c.categoryIds);
  const customerIds = strings(c.customerIds);
  return {
    id: r.id,
    source: r.source,
    name: r.name,
    kind: r.kind,
    value: r.value,
    appliesAutomatically: r.applies_automatically,
    isActive: r.is_active,
    validFrom: r.valid_from,
    validTo: r.valid_to,
    conditions: {
      ...(typeof c.minTotal === 'string' ? { minTotal: c.minTotal } : {}),
      ...(categoryIds ? { categoryIds } : {}),
      ...(customerIds ? { customerIds } : {}),
    },
    description: r.description_ru,
  };
}

/** Правило относится к клиенту: без условия по клиентам или клиент в `customerIds` / `partnerRefs` (ref 1С). */
function appliesTo(r: RuleRow, customerId: string, onecRef: string | null): boolean {
  const c = r.conditions;
  const ids = Array.isArray(c.customerIds) ? (c.customerIds as unknown[]) : null;
  const refs = Array.isArray(c.partnerRefs) ? (c.partnerRefs as unknown[]) : null;
  if (!ids && !refs) return true;
  return Boolean(ids?.includes(customerId) || (onecRef !== null && refs?.includes(onecRef)));
}

const RULE_COLUMNS = sql`id, source::text AS source, name, kind::text AS kind, value::text AS value,
  applies_automatically, is_active, to_char(valid_from, 'YYYY-MM-DD') AS valid_from,
  to_char(valid_to, 'YYYY-MM-DD') AS valid_to, conditions, description_ru, synced_at`;

/**
 * `DiscountPolicyPort` (RM-G-003; 06 §7.4 `DiscountService.limitFor(role)`; 10 DISC-003, DISC-007, DISC-010,
 * DISC-013; ядро §22.10 — лимиты только по ролям, D-23):
 *
 * - `limits` — строки `role_discount_limits` (seed: seller 5 / cashier 5 / senior_seller 10 / admin 15 / owner 0 —
 *   [НЕ ПОДТВЕРЖДЕНО: Q-015]; меняет админ — `PUT /admin/discount-limits`);
 * - `limitFor` — максимум `max_percent` по ролям субъекта; режим клиента и роль без строки — `"0.00"` (fail-closed);
 * - `canApproveOverLimit` — право `discount.approve.over_limit` **и** роль с `can_approve_over_limit`, процент не выше
 *   её потолка подтверждения (`approve_max_percent`, не задан — `max_percent`: тот же порог, что применяет корзина
 *   этапа F, `checkManualDiscount`, GQ-CRD-07);
 * - `activeRules` / `customerTerms` — реплика 1С `discount_rules` (`is_active`, без пометки удаления, период по дате
 *   Бишкека) и условия соглашения клиента (`customers`). Автоматические скидки 1С не воспроизводятся (DISC-006,
 *   DISC-015): правила только показываются, итог 1С — истина.
 */
@Injectable()
export class DiscountPolicyService implements DiscountPolicyPort {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly catalog: PermissionCatalog,
  ) {}

  private ex(tx: SalesTx | null): DbExecutor {
    return tx ?? this.db;
  }

  async limits(tx: SalesTx | null): Promise<readonly RoleDiscountLimitView[]> {
    const r = await this.ex(tx).execute<{
      role: RoleCode;
      max_percent: string;
      can_approve_over_limit: boolean;
      approve_max_percent: string | null;
      requires_reason_over_percent: string | null;
      row_version: number;
    }>(sql`
      SELECT role::text AS role, max_percent::text AS max_percent, can_approve_over_limit,
             approve_max_percent::text AS approve_max_percent,
             requires_reason_over_percent::text AS requires_reason_over_percent, row_version
        FROM role_discount_limits ORDER BY role`);
    return r.rows.map((x) => ({
      role: x.role,
      maxPercent: pct(x.max_percent),
      canApproveOverLimit: x.can_approve_over_limit,
      approveMaxPercent: x.approve_max_percent === null ? null : pct(x.approve_max_percent),
      requiresReasonOverPercent: x.requires_reason_over_percent === null ? null : pct(x.requires_reason_over_percent),
      rowVersion: x.row_version,
    }));
  }

  async limitFor(tx: SalesTx | null, actor: SalesActor): Promise<string> {
    if (actor.isCustomer) return '0.00';
    let best = 0n;
    for (const row of await this.limits(tx)) {
      if (!actor.roles.includes(row.role)) continue;
      const v = percentToHundredths(row.maxPercent);
      if (v > best) best = v;
    }
    return hundredthsToPercent(best);
  }

  async canApproveOverLimit(tx: SalesTx | null, actor: SalesActor, percent: string): Promise<boolean> {
    if (actor.isCustomer) return false;
    const requested = hundredths(percent);
    if (requested === null) return false;
    if (!this.catalog.effectivePermissions({ roles: actor.roles }).has('discount.approve.over_limit')) return false;
    for (const row of await this.limits(tx)) {
      if (!actor.roles.includes(row.role) || !row.canApproveOverLimit) continue;
      const ceiling = percentToHundredths(row.approveMaxPercent ?? row.maxPercent);
      if (requested <= ceiling) return true;
    }
    return false;
  }

  async activeRules(tx: SalesTx | null, on: Date = new Date()): Promise<readonly DiscountRuleView[]> {
    return (await this.activeRows(tx, on)).map(ruleView);
  }

  private async activeRows(tx: SalesTx | null, on: Date): Promise<RuleRow[]> {
    const day = bishkekDay(on);
    const r = await this.ex(tx).execute<RuleRow>(sql`
      SELECT ${RULE_COLUMNS} FROM discount_rules
       WHERE is_active AND NOT deletion_mark AND deleted_at IS NULL
         AND (valid_from IS NULL OR valid_from <= ${day}::date)
         AND (valid_to IS NULL OR valid_to >= ${day}::date)
       ORDER BY name, id`);
    return r.rows;
  }

  async customerTerms(
    tx: SalesTx | null,
    customerId: string,
    on: Date = new Date(),
  ): Promise<CustomerDiscountTerms | null> {
    const c = await this.ex(tx).execute<{
      id: string;
      onec_ref: string | null;
      default_price_list_id: string | null;
      discount_percent: string | null;
      credit_allowed: boolean;
      credit_days: number | null;
      credit_limit: string | null;
      synced_at: Date | string | null;
    }>(sql`
      SELECT id, onec_ref, default_price_list_id, discount_percent::text AS discount_percent, credit_allowed,
             credit_days, credit_limit::text AS credit_limit, synced_at
        FROM customers WHERE id = ${customerId}::uuid AND deleted_at IS NULL`);
    const row = c.rows[0];
    if (!row) return null;
    const rules = (await this.activeRows(tx, on)).filter((r) => appliesTo(r, row.id, row.onec_ref));
    const stamps = [row.synced_at, ...rules.map((r) => r.synced_at)]
      .filter((x): x is Date | string => x !== null)
      .map((x) => new Date(x).getTime());
    return {
      customerId: row.id,
      priceListId: row.default_price_list_id,
      customerDiscountPercent: row.discount_percent === null ? null : pct(row.discount_percent),
      rules: rules.map(ruleView),
      creditAllowed: row.credit_allowed,
      paymentTermDays: row.credit_days,
      creditLimit: row.credit_limit,
      asOf: stamps.length > 0 ? new Date(Math.max(...stamps)) : on,
    };
  }
}
