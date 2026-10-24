import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { type AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { Money } from '../../common/money/money.js';
import {
  DISCOUNT_POLICY_PORT,
  type DiscountPolicyPort,
  type DiscountRuleView,
  PortNotBoundError,
  RECEIVABLES_SNAPSHOT_PORT,
  type ReceivablesSnapshotPort,
  type SalesActor,
} from '../../common/ports/index.js';
import type { CustomerViewer } from './customer-access.js';
import { moneyDto } from './customer-projector.js';
import type { CustomerRow } from './customer-rows.js';

/** Субъект порта из субъекта HTTP. */
export function salesActorOf(v: CustomerViewer, requestId: string | null = null): SalesActor {
  return {
    userId: v.userId,
    roles: v.roles,
    isCustomer: v.isCustomer,
    sessionId: v.principal.sessionId ?? null,
    deviceId: v.principal.deviceId ?? null,
    requestId,
  };
}

/**
 * Финансовые части карточки клиента (08 §3.7; 10 DEBT-002, DISC-013): сводка долга `ReceivableSummary` — только из
 * снимка 1С (`RECEIVABLES_SNAPSHOT_PORT`, D-24; backend долг не вычисляет), остаток лимита =
 * `creditLimit − balance − openOrdersAmount` (DEBT-002, DEBT-011); скидки и условия — `DISCOUNT_POLICY_PORT`
 * (состав `CustomersDiscountsResponse`, 08 §4.11.6). Реализации портов — агент G-be-credit; пока порт не привязан,
 * часть не отдаётся (fail-closed: нет данных — нет сумм), в журнал — предупреждение.
 *
 * Аудит `customer.debt_viewed` (11 SEC-031, SEC-032; 08 §4.11.3): каждый ответ, содержащий суммы долга.
 */
@Injectable()
export class CustomerFinanceService {
  private readonly logger = new Logger('customers.finance');

  constructor(
    private readonly audit: AuditService,
    // Токены портов даёт глобальный `SalesPortsModule`; стенды без него (каталог E) — как непривязанный порт.
    @Optional() @Inject(RECEIVABLES_SNAPSHOT_PORT) private readonly receivables?: ReceivablesSnapshotPort,
    @Optional() @Inject(DISCOUNT_POLICY_PORT) private readonly discounts?: DiscountPolicyPort,
  ) {}

  /**
   * `ReceivableSummary` или `null`: клиент не в 1С (`source=pos` до подтверждения — `not_in_onec`), «Розничный
   * покупатель» (CUST-018), снимка нет (DEBT-009) или порт не привязан.
   */
  async receivableSummary(row: CustomerRow): Promise<Record<string, unknown> | null> {
    if (row.isRetailDefault || row.onecRef === null) return null;
    try {
      if (!this.receivables) throw new PortNotBoundError(RECEIVABLES_SNAPSHOT_PORT);
      const s = await this.receivables.snapshot(null, row.id);
      if (!s) return null;
      const out: Record<string, unknown> = { balance: moneyDto(s.balance) };
      if (s.overdueAmount !== null) out.overdueAmount = moneyDto(s.overdueAmount);
      if (row.creditLimit !== null) {
        const open = await this.receivables.openOrdersAmount(null, row.id);
        out.creditLimit = moneyDto(row.creditLimit);
        out.limitRemaining = moneyDto(
          Money.of(row.creditLimit).minus(Money.of(s.balance)).minus(Money.of(open)).toString(),
        );
      }
      out.asOf = s.snapshotAt.toISOString();
      return out;
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.logger.warn({ event: 'customers.receivable.port_unbound' }, 'ReceivablesSnapshotPort не привязан');
        return null;
      }
      throw e;
    }
  }

  /** `CustomersDiscountsResponse` (08 §4.11.6) или `null` (клиента нет / порт не привязан / «Розничный»). */
  async discountsBlock(row: CustomerRow, actor: SalesActor, amounts: boolean): Promise<Record<string, unknown> | null> {
    if (row.isRetailDefault) return null;
    try {
      if (!this.discounts) throw new PortNotBoundError(DISCOUNT_POLICY_PORT);
      const terms = await this.discounts.customerTerms(null, row.id);
      if (!terms) return null;
      const limit = await this.discounts.limitFor(null, actor);
      return {
        priceList:
          terms.priceListId && terms.priceListId === row.priceListId && row.priceListName
            ? { id: row.priceListId, name: row.priceListName }
            : null,
        customerDiscountPercent: terms.customerDiscountPercent,
        rules: terms.rules.map(discountRuleDto),
        creditTerms: {
          creditAllowed: terms.creditAllowed,
          paymentTermDays: terms.paymentTermDays,
          ...(amounts ? { creditLimit: terms.creditLimit === null ? null : moneyDto(terms.creditLimit) } : {}),
        },
        manualDiscountLimitPercent: limit,
        asOf: terms.asOf.toISOString(),
      };
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.logger.warn({ event: 'customers.discounts.port_unbound' }, 'DiscountPolicyPort не привязан');
        return null;
      }
      throw e;
    }
  }

  /** Аудит `customer.debt_viewed` (объём `summary` / `history`); ПДн не пишутся. */
  /**
   * Аудит `customer.debt_viewed` (11 §7.2: `customer_id`, объём `summary|detail`, `snapshot_at`; SEC-032) — единый
   * формат с `ReceivablesService` (`scope`, `snapshotAt`); `via` — путь просмотра (ревью G-security-8).
   */
  async debtViewed(
    ctx: AuditContext,
    customerId: string,
    after: Readonly<{ scope: string; snapshotAt: unknown; via: string } & Record<string, unknown>>,
  ): Promise<void> {
    await this.audit.write(ctx, {
      action: 'customer.debt_viewed',
      entityType: 'customer',
      entityId: customerId,
      after,
    });
  }
}

function discountRuleDto(r: DiscountRuleView): Record<string, unknown> {
  return {
    id: r.id,
    source: r.source,
    name: r.name,
    kind: r.kind,
    value: r.value,
    isActive: r.isActive,
    conditions: {
      minTotal: r.conditions.minTotal ? moneyDto(r.conditions.minTotal) : null,
      ...(r.conditions.categoryIds ? { categoryIds: [...r.conditions.categoryIds] } : {}),
      ...(r.conditions.customerIds ? { customerIds: [...r.conditions.customerIds] } : {}),
    },
  };
}
