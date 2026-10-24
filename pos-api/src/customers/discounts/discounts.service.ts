import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { principalOf } from '../../admin/users/shared/principal.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Money } from '../../common/money/money.js';
import type { DiscountRuleView, SalesActor } from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { RBAC_ROLES, type RbacRole } from '../../common/rbac/permissions.generated.js';
import { DiscountPolicyService } from './discount-policy.service.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Роли в `limitsByRole` (`DiscountsRulesResponse`; 08 §4.12.2) — сотрудники. */
const STAFF_ROLES: readonly RbacRole[] = ['seller', 'cashier', 'senior_seller', 'admin', 'owner'];

type Query = Record<string, unknown>;

function uuidOf(v: unknown, field: string): string {
  if (typeof v !== 'string' || !UUID_RE.test(v)) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Запрос не прошёл проверку.',
      errors: [{ field, rule: 'uuid', message: 'Ожидается UUID.' }],
    });
  }
  return v.toLowerCase();
}

function actorOf(p: AuthenticatedPrincipal): SalesActor {
  return {
    userId: p.userId,
    roles: p.roles,
    isCustomer: p.kind === 'customer',
    sessionId: p.sessionId,
    deviceId: p.deviceId,
  };
}

/**
 * `DiscountRule` (08 §3.x; 07 §5.33): условия по клиентам сужаются до клиента запроса (`only`), чтобы ответ не
 * раскрывал другие карточки (минимизация, 11 SEC-031).
 */
export function presentRule(r: DiscountRuleView, only?: string): Record<string, unknown> {
  const ids = r.conditions.customerIds;
  const customerIds = ids === undefined ? undefined : only === undefined ? ids : ids.filter((x) => x === only);
  return {
    id: r.id,
    source: r.source,
    name: r.name,
    kind: r.kind,
    value: r.value,
    isActive: r.isActive,
    conditions: {
      ...(r.conditions.minTotal !== undefined ? { minTotal: Money.of(r.conditions.minTotal).toJSON() } : {}),
      ...(r.conditions.categoryIds ? { categoryIds: r.conditions.categoryIds } : {}),
      ...(customerIds !== undefined ? { customerIds } : {}),
    },
  };
}

/**
 * Скидки и условия (RM-G-003; 08 §4.11.6 `GET /customers/{id}/discounts` — SCR-35; §4.12.2 `GET /discounts/rules`;
 * 10 DISC-005, DISC-007, DISC-013, DEBT-008). Право `discount.rules.read`; роль `customer` — только своя карточка с
 * привязкой `confirmed` (11 §4.4 `own`), иначе `403 FORBIDDEN`. Лимит ручной скидки — текущей роли
 * (`role_discount_limits`, Q-015). `creditTerms.creditLimit` — только с правом на суммы долга (SEC-031). Аудит не
 * пишется.
 */
@Injectable()
export class DiscountsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly policy: DiscountPolicyService,
    private readonly catalog: PermissionCatalog,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>,
  ) {}

  /** Режим клиента выключен (CUSTOMER_SELF_SERVICE=false) → `403` для `customer` (10 CASH-006; ревью G-security-2). */
  private assertSelfService(actor: SalesActor): void {
    if (actor.isCustomer && !this.config.CUSTOMER_SELF_SERVICE) {
      throw new ProblemException('FORBIDDEN', { detail: 'Режим клиента отключён.' });
    }
  }

  async customerDiscounts(req: RequestWithContext, rawId: string): Promise<Record<string, unknown>> {
    const p = principalOf(req);
    const id = uuidOf(rawId, 'id');
    const actor = actorOf(p);
    this.assertSelfService(actor);
    // Клиент: чужая и несуществующая карточка неразличимы — `404` (11 SEC-030 (в), владелец RBAC — ядро §18.1;
    // ревью G-security-5). Проверка привязки — до поиска условий.
    if (actor.isCustomer) await this.assertOwn(p.userId, id);
    const terms = await this.policy.customerTerms(null, id);
    if (!terms) throw new ProblemException('NOT_FOUND', { detail: 'Клиент не найден.' });
    const perms = this.catalog.effectivePermissions(p);
    const amountsAllowed = actor.isCustomer
      ? perms.has('customer.self.receivables.read')
      : perms.has('customer.receivables.read.summary');
    const priceList = terms.priceListId ? await this.priceList(terms.priceListId) : null;
    return {
      priceList,
      customerDiscountPercent: terms.customerDiscountPercent,
      rules: terms.rules.map((r) => presentRule(r, id)),
      creditTerms: {
        creditAllowed: terms.creditAllowed,
        paymentTermDays: terms.paymentTermDays,
        ...(amountsAllowed
          ? { creditLimit: terms.creditLimit === null ? null : Money.of(terms.creditLimit).toJSON() }
          : {}),
      },
      manualDiscountLimitPercent: await this.policy.limitFor(null, actor),
      asOf: terms.asOf.toISOString(),
    };
  }

  async rules(req: RequestWithContext, q: Query): Promise<Record<string, unknown>> {
    const p = principalOf(req);
    const actor = actorOf(p);
    this.assertSelfService(actor);
    let customerId: string | null = q.customerId === undefined ? null : uuidOf(q.customerId, 'customerId');
    const cartId: string | null = q.cartId === undefined ? null : uuidOf(q.cartId, 'cartId');
    if (cartId !== null) {
      const cart = await this.db.execute<{ customer_id: string | null }>(
        sql`SELECT customer_id FROM carts WHERE id = ${cartId}::uuid AND owner_user_id = ${p.userId}::uuid`,
      );
      if (cart.rows.length === 0) throw new ProblemException('NOT_FOUND', { detail: 'Корзина не найдена.' });
      customerId ??= cart.rows[0].customer_id;
    }
    if (actor.isCustomer) {
      // Роль customer — только правила своей подтверждённой карточки (08 §4.12.2, 11 §4.4).
      const own = await this.confirmedCustomerOf(p.userId);
      if (own === null || (customerId !== null && customerId !== own)) {
        throw new ProblemException('FORBIDDEN', { detail: 'Правила скидок доступны только для своей карточки.' });
      }
      customerId = own;
    }
    let rules: readonly DiscountRuleView[];
    if (customerId !== null) {
      const terms = await this.policy.customerTerms(null, customerId);
      if (!terms) throw new ProblemException('NOT_FOUND', { detail: 'Клиент не найден.' });
      rules = terms.rules;
    } else {
      rules = await this.policy.activeRules(null);
    }
    const body: Record<string, unknown> = {
      rules: rules.map((r) => presentRule(r, customerId ?? undefined)),
      manualDiscountLimitPercent: await this.policy.limitFor(null, actor),
    };
    if (!actor.isCustomer) {
      const limits = await this.policy.limits(null);
      body.overrideRoles = limits
        .filter((l) => l.canApproveOverLimit && this.roleCanApprove(l.role))
        .map((l) => l.role);
      body.limitsByRole = Object.fromEntries(
        limits.filter((l) => STAFF_ROLES.includes(l.role)).map((l) => [l.role, l.maxPercent]),
      );
    }
    return body;
  }

  /** Роль держит право `discount.approve.over_limit` (каталог прав 11 §4.3). */
  roleCanApprove(role: string): boolean {
    return (
      (RBAC_ROLES as readonly string[]).includes(role) &&
      this.catalog.effectivePermissions({ roles: [role] }).has('discount.approve.over_limit')
    );
  }

  private async assertOwn(userId: string, customerId: string): Promise<void> {
    if ((await this.confirmedCustomerOf(userId)) !== customerId) {
      throw new ProblemException('NOT_FOUND', { detail: 'Клиент не найден.' });
    }
  }

  private async confirmedCustomerOf(userId: string): Promise<string | null> {
    const r = await this.db.execute<{ customer_id: string }>(sql`
      SELECT customer_id FROM customer_links WHERE user_id = ${userId}::uuid AND status = 'confirmed' LIMIT 1`);
    return r.rows[0]?.customer_id ?? null;
  }

  private async priceList(id: string): Promise<{ id: string; name: string } | null> {
    const r = await this.db.execute<{ id: string; name: string }>(
      sql`SELECT id, name FROM price_lists WHERE id = ${id}::uuid`,
    );
    return r.rows[0] ?? null;
  }
}
