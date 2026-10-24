import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { ROLE_CODE_VALUES, type RoleCode } from '../../common/enums.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { hundredthsToPercent } from '../../sales-domain/pricing/percent.js';
import { principalOf } from '../users/shared/principal.js';
import { verifiedStepUp } from '../users/shared/step-up.guard.js';

/** Роли тела `limits` (`AdminDiscountLimitsByRole`, 08 §4.18.5). */
export const LIMIT_ROLES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner'] as const;
type LimitRole = (typeof LIMIT_ROLES)[number];

/** `Percent` контракта: `^(\d{1,2}(\.\d{1,2})?|100\.00)$` (08 §2.14, rule `percent_range`). */
const PERCENT_RE = /^(\d{1,2}(\.\d{1,2})?|100\.00)$/;

export interface AdminDiscountLimitsBody {
  readonly limits: Record<LimitRole, string>;
  readonly overrideRoles: RoleCode[];
  readonly rowVersion: number;
  readonly updatedAt: string | null;
  readonly updatedBy: { id: string; displayName: string; role?: string } | null;
}

interface LimitRow extends Record<string, unknown> {
  role: RoleCode;
  max_percent: string;
  can_approve_over_limit: boolean;
  row_version: number;
  updated_at: Date | string;
  updated_by_user_id: string | null;
}

function canonPercent(v: string): string {
  const [i, f = ''] = v.split('.');
  return hundredthsToPercent(BigInt(i ?? '0') * 100n + BigInt(f.padEnd(2, '0')));
}

function invalid(status: 400 | 422, errors: ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail: 'Лимиты скидок не прошли проверку.', errors });
}

/**
 * Лимиты ручной скидки по ролям `GET/PUT /admin/discount-limits` (08 §4.18.5; SCR-46; RM-G-003; 10 DISC-003,
 * DISC-012; 07 §5.34 `role_discount_limits`; значения — [НЕ ПОДТВЕРЖДЕНО: Q-015]).
 *
 * - `limits` — `max_percent` ролей seller/cashier/senior_seller/admin/owner; `overrideRoles` — роли с
 *   `can_approve_over_limit = true`; допускаются только роли, которым каталог прав (11 §4.3) даёт
 *   `discount.approve.over_limit` (иначе флаг ничего не разрешал бы — `422`, rule `role_cannot_approve`, GQ-CRD-08);
 * - `rowVersion` — сумма `row_version` всех строк таблицы (каждое изменение строки её увеличивает → устаревшая
 *   версия всегда обнаруживается, `409 VERSION_CONFLICT`); повтор того же тела → `200` без изменений и без проверки
 *   версии (08 §4.18.5: «повтор того же тела → 200 без изменений»);
 * - PUT — только `admin` со step-up `settings.discount_limits.update` (guard контроллера), транзакция с
 *   advisory-lock, аудит `discount.limits_changed` (before/after, метод step-up, причина формируется сервером —
 *   SEC-076; в теле запроса поля `reason` нет) + построчный аудит уровня БД (триггер `role_discount_limits`).
 *   Новые лимиты действуют сразу: корзина читает `role_discount_limits` при каждом расчёте.
 */
@Injectable()
export class AdminDiscountLimitsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly audit: AuditService,
    private readonly catalog: PermissionCatalog,
  ) {}

  async get(): Promise<AdminDiscountLimitsBody> {
    return this.present(this.db, await this.load(this.db));
  }

  async update(req: RequestWithContext, body: unknown): Promise<AdminDiscountLimitsBody> {
    const actor = principalOf(req);
    const next = this.validate(body);
    const ctx = auditContextFromRequest(req);
    const rows = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext('role_discount_limits'))`);
      const current = await this.load(tx);
      const before = this.view(current);
      const changed = current.filter((r) => {
        const limit = (LIMIT_ROLES as readonly string[]).includes(r.role)
          ? next.limits[r.role as LimitRole]
          : canonPercent(r.max_percent);
        return canonPercent(r.max_percent) !== limit || r.can_approve_over_limit !== next.overrideRoles.has(r.role);
      });
      if (changed.length === 0) return current;
      if (next.rowVersion !== before.rowVersion) {
        throw new ProblemException('VERSION_CONFLICT', {
          detail: 'Лимиты скидок изменились. Обновите экран и повторите.',
          current: { rowVersion: before.rowVersion },
        });
      }
      for (const r of changed) {
        const limit = (LIMIT_ROLES as readonly string[]).includes(r.role) ? next.limits[r.role as LimitRole] : null;
        await tx.execute(sql`
          UPDATE role_discount_limits
             SET max_percent = coalesce(${limit}::numeric, max_percent),
                 can_approve_over_limit = ${next.overrideRoles.has(r.role)},
                 updated_by_user_id = ${actor.userId}::uuid, row_version = row_version + 1, updated_at = now()
           WHERE role = ${r.role}::role_code`);
      }
      const after = await this.load(tx);
      const afterView = this.view(after);
      await this.audit.write(
        ctx,
        {
          action: 'discount.limits_changed',
          entityType: 'role_discount_limits',
          before: { limits: before.limits, overrideRoles: before.overrideRoles },
          after: { limits: afterView.limits, overrideRoles: afterView.overrideRoles },
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
          reason: `Изменение лимитов ручной скидки по ролям (SCR-46): ${changed.map((r) => r.role).join(', ')}`,
        },
        tx,
      );
      return after;
    });
    return this.present(this.db, rows);
  }

  /** Ответ с `updatedBy` (`UserRef` без телефона, 08 §3.5) — автор последнего изменения строк. */
  private async present(ex: DbExecutor, rows: readonly LimitRow[]): Promise<AdminDiscountLimitsBody> {
    const v = this.view(rows);
    const latest = rows
      .filter((r) => r.updated_by_user_id !== null)
      .sort((a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime())[0];
    if (!latest) return v;
    const u = await ex.execute<{
      id: string;
      display_name: string | null;
      full_name: string | null;
      role: string | null;
    }>(sql`
      SELECT u.id, p.display_name, p.full_name,
             (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
               WHERE ur.user_id = u.id AND ur.revoked_at IS NULL LIMIT 1) AS role
        FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
       WHERE u.id = ${latest.updated_by_user_id}::uuid`);
    const row = u.rows[0];
    return row
      ? {
          ...v,
          updatedBy: {
            id: row.id,
            displayName: row.display_name ?? row.full_name ?? 'Пользователь',
            ...(row.role ? { role: row.role } : {}),
          },
        }
      : v;
  }

  /** Тело PUT: формат (400 `percent_range`, роли, лишние поля) → значения (422). */
  private validate(body: unknown): {
    limits: Record<LimitRole, string>;
    overrideRoles: Set<string>;
    rowVersion: number;
  } {
    const errors400: ProblemFieldError[] = [];
    const b = (body ?? {}) as Record<string, unknown>;
    for (const k of Object.keys(b)) {
      if (!['limits', 'overrideRoles', 'rowVersion'].includes(k)) {
        errors400.push({ field: k, rule: 'additional_properties', message: 'Лишнее поле.' });
      }
    }
    const limits = {} as Record<LimitRole, string>;
    const l = b.limits;
    if (l === null || typeof l !== 'object' || Array.isArray(l)) {
      errors400.push({ field: 'limits', rule: 'required', message: 'Ожидается объект лимитов по ролям.' });
    } else {
      const obj = l as Record<string, unknown>;
      for (const k of Object.keys(obj)) {
        if (!(LIMIT_ROLES as readonly string[]).includes(k)) {
          errors400.push({ field: `limits.${k}`, rule: 'additional_properties', message: 'Неизвестная роль.' });
        }
      }
      for (const role of LIMIT_ROLES) {
        const v = obj[role];
        if (v === undefined) errors400.push({ field: `limits.${role}`, rule: 'required', message: 'Обязательно.' });
        else if (typeof v !== 'string' || !PERCENT_RE.test(v)) {
          errors400.push({ field: `limits.${role}`, rule: 'percent_range', message: 'Процент 0…100, до 2 знаков.' });
        } else limits[role] = canonPercent(v);
      }
    }
    const roles = b.overrideRoles;
    const overrideRoles = new Set<string>();
    if (!Array.isArray(roles) || roles.length > ROLE_CODE_VALUES.length) {
      errors400.push({ field: 'overrideRoles', rule: 'type', message: 'Ожидается массив ролей.' });
    } else {
      roles.forEach((r, i) => {
        if (typeof r !== 'string' || !(ROLE_CODE_VALUES as readonly string[]).includes(r)) {
          errors400.push({ field: `overrideRoles[${i}]`, rule: 'enum', message: 'Неизвестная роль.' });
        } else if (overrideRoles.has(r)) {
          errors400.push({ field: `overrideRoles[${i}]`, rule: 'unique_items', message: 'Роль повторяется.' });
        } else overrideRoles.add(r);
      });
    }
    const rv = b.rowVersion;
    if (typeof rv !== 'number' || !Number.isInteger(rv) || rv < 0) {
      errors400.push({ field: 'rowVersion', rule: 'minimum', message: 'Целое ≥ 0.' });
    }
    if (errors400.length > 0) throw invalid(400, errors400);
    const errors422: ProblemFieldError[] = [];
    for (const r of overrideRoles) {
      if (!this.catalog.effectivePermissions({ roles: [r] }).has('discount.approve.over_limit')) {
        errors422.push({
          field: 'overrideRoles',
          rule: 'role_cannot_approve',
          message: `Роль ${r} не может подтверждать скидку сверх лимита (нет права discount.approve.over_limit).`,
        });
      }
    }
    if (errors422.length > 0) throw invalid(422, errors422);
    return { limits, overrideRoles, rowVersion: rv as number };
  }

  private async load(ex: DbExecutor): Promise<LimitRow[]> {
    const r = await ex.execute<LimitRow>(sql`
      SELECT role::text AS role, max_percent::text AS max_percent, can_approve_over_limit, row_version, updated_at,
             updated_by_user_id
        FROM role_discount_limits ORDER BY role`);
    return r.rows;
  }

  private view(rows: readonly LimitRow[]): AdminDiscountLimitsBody {
    const limits = Object.fromEntries(LIMIT_ROLES.map((role) => [role, '0.00'])) as Record<LimitRole, string>;
    for (const r of rows)
      if ((LIMIT_ROLES as readonly string[]).includes(r.role))
        limits[r.role as LimitRole] = canonPercent(r.max_percent);
    const latest = rows.reduce<LimitRow | null>(
      (m, r) => (m === null || new Date(r.updated_at).getTime() > new Date(m.updated_at).getTime() ? r : m),
      null,
    );
    return {
      limits,
      overrideRoles: rows.filter((r) => r.can_approve_over_limit).map((r) => r.role),
      rowVersion: rows.reduce((s, r) => s + r.row_version, 0),
      updatedAt: latest ? new Date(latest.updated_at).toISOString() : null,
      updatedBy: null,
    };
  }
}
