import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { Money } from '../../common/money/money.js';
import {
  type CreditCheckInput,
  type CreditCheckResult,
  type CreditDecisionService,
  RECEIVABLES_SNAPSHOT_PORT,
  type ReceivablesSnapshotPort,
  type ReceivablesSnapshotView,
  type SalesTx,
} from '../../common/ports/index.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import {
  type CreditCustomer,
  type CreditDecision,
  type CreditDecisionInput,
  decideCredit,
  type ReceivablesSnapshot,
} from '../credit/credit-decision.js';

/** Карточка клиента для решения о долге (шаг 1 PAY-031): строка `customers`. */
export interface CreditCustomerRow {
  readonly isRetailDefault: boolean;
  readonly onecRef: string | null;
  readonly deletionMark: boolean;
  readonly deleted: boolean;
  readonly creditAllowed: boolean;
  /** `NUMERIC(14,2)` строкой; `null` — лимит в 1С не задан (DEBT-012). */
  readonly creditLimit: string | null;
}

/**
 * Чтение карточки клиента для решения о долге — **в транзакции вызывающего** (`tx`), чтобы условия соглашения и
 * снимок долга читались согласованно. Порт `CustomerReader` (G-be-customers) не используется намеренно: решение о
 * долге должно оставаться fail-closed и при непривязанном порте (`PortNotBoundError` дал бы 500 вместо 422).
 */
@Injectable()
export class CreditCustomerLookup {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async load(tx: SalesTx | null, customerId: string): Promise<CreditCustomerRow | null> {
    const ex = tx ?? this.db;
    const r = await ex.execute<{
      is_retail_default: boolean;
      onec_ref: string | null;
      deletion_mark: boolean;
      deleted: boolean;
      credit_allowed: boolean;
      credit_limit: string | null;
    }>(sql`
      SELECT is_retail_default, onec_ref, deletion_mark, deleted_at IS NOT NULL AS deleted, credit_allowed,
             credit_limit::text AS credit_limit
        FROM customers WHERE id = ${customerId}::uuid`);
    const row = r.rows[0];
    if (!row) return null;
    return {
      isRetailDefault: row.is_retail_default,
      onecRef: row.onec_ref,
      deletionMark: row.deletion_mark,
      deleted: row.deleted,
      creditAllowed: row.credit_allowed,
      creditLimit: row.credit_limit,
    };
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function toDomainSnapshot(v: ReceivablesSnapshotView | null): ReceivablesSnapshot | null {
  if (!v) return null;
  return {
    balance: Money.of(v.balance),
    overdueAmount: v.overdueAmount === null ? null : Money.of(v.overdueAmount),
    snapshotAt: v.snapshotAt,
  };
}

function toCreditCustomer(c: CreditCustomerRow | null): CreditCustomer | null {
  if (!c) return null;
  return {
    isRetailDefault: c.isRetailDefault,
    // Помеченная на удаление/удалённая карточка — не идентифицированный клиент (как CheckoutPolicy этапа F).
    hasOnecRef: c.onecRef !== null && !c.deletionMark && !c.deleted,
    creditAllowed: c.creditAllowed,
    creditLimit: c.creditLimit === null ? null : Money.of(c.creditLimit),
  };
}

/**
 * Реальная реализация `CreditDecisionService` (RM-G-002; замена fail-closed-заглушки этапа F
 * `FailClosedCreditDecisionService`; контракт порта не меняется). Порядок решения — чистая функция `decideCredit`
 * (10 PAY-031, ядро §22.4 в редакции §23 п. 5); эта обёртка только поставляет данные:
 *
 * 1. право `credit.sale.create` (каталог прав по ролям субъекта; режим клиента — нет права) и карточка клиента —
 *    **до** чтения снимка и без обращения к 1С: отказ шага 1 возвращается сразу;
 * 2. снимок долга (`ReceivablesSnapshotPort.snapshot`, любой возраст), прогноз открытых заказов в долг
 *    (`openOrdersAmount`, DEBT-011) и `RECEIVABLES_MAX_AGE_MIN` — известная блокировка без обращения к 1С;
 * 3. снимок отсутствует, неполон или устарел → одно синхронное обновление (`ReceivablesSnapshotPort.refresh`,
 *    таймаут `ONEC_SYNC_CHECK_TIMEOUT_MS`, без исключений при недоступности 1С) и повтор шагов 2–4 по новому снимку;
 *    `unavailable` / `not_in_onec` → `422 RECEIVABLES_STALE`. Код `ONEC_UNAVAILABLE` для долга не возвращается.
 *
 * `creditOverride` (PAY-032) учитывается, только если у субъекта есть `credit.sale.approve` (step-up проверяет
 * вызывающий: orders/cart); он снимает **только** блокировки шага 2 (DEBT-010).
 */
@Injectable()
export class SnapshotCreditDecisionService implements CreditDecisionService {
  private readonly logger = new Logger('credit.decision');
  /** Источник времени возраста снимка (подмена — тесты). */
  now: () => Date = () => new Date();

  constructor(
    private readonly customers: CreditCustomerLookup,
    @Inject(RECEIVABLES_SNAPSHOT_PORT) private readonly receivables: ReceivablesSnapshotPort,
    private readonly catalog: PermissionCatalog,
  ) {}

  async check(tx: SalesTx | null, input: CreditCheckInput): Promise<CreditCheckResult> {
    const permissions = this.catalog.effectivePermissions({ roles: input.actor.roles });
    const canSellOnCredit = !input.actor.isCustomer && permissions.has('credit.sale.create');
    const override = input.override !== null && canSellOnCredit && permissions.has('credit.sale.approve');
    const total = Money.of(input.total);
    const customerRow =
      canSellOnCredit && input.customerId !== null && UUID_RE.test(input.customerId)
        ? await this.customers.load(tx, input.customerId)
        : null;
    const base: Omit<CreditDecisionInput, 'snapshot' | 'openOrdersAmount' | 'maxAgeMinutes' | 'now'> = {
      canSellOnCredit,
      customer: toCreditCustomer(customerRow),
      total,
      override,
    };
    // Шаг 1 — без снимка и 1С: `decideCredit` с пустым снимком возвращает отказ шага 1 или требует данные.
    const first = decideCredit({
      ...base,
      snapshot: null,
      openOrdersAmount: Money.ZERO,
      maxAgeMinutes: 0,
      now: this.now(),
      refresh: 'unavailable',
    });
    if (first.kind === 'refused' && first.step === 1) return this.result(first, input);

    const customerId = input.customerId as string;
    const maxAgeMinutes = await this.receivables.maxAgeMinutes();
    const openOrdersAmount = Money.of(await this.receivables.openOrdersAmount(tx, customerId));
    const decide = async (b: typeof base, refresh?: 'refreshed' | 'unavailable'): Promise<CreditDecision> => {
      const now = this.now();
      return decideCredit({
        ...b,
        snapshot: toDomainSnapshot(await this.receivables.snapshot(tx, customerId, now)),
        openOrdersAmount,
        maxAgeMinutes,
        now,
        ...(refresh ? { refresh } : {}),
      });
    };
    let d = await decide(base);
    if (d.kind === 'refresh_required' && input.allowRefresh === false) {
      // Повторная проверка в транзакции заказа (08 API-071, ревью G-credit-3): без обращения к 1С — fail-closed.
      d = await decide(base, 'unavailable');
    } else if (d.kind === 'refresh_required') {
      const r = await this.receivables.refresh(customerId, { actor: input.actor });
      if (r.kind !== 'refreshed') {
        this.logger.warn(
          { event: 'credit.receivables_refresh_failed', customerId, outcome: r.kind },
          'credit: обновление снимка долга не выполнено — fail-closed',
        );
        d = await decide(base, 'unavailable');
      } else {
        // Обновление из 1С переписывает и условия соглашения клиента (credit_allowed, credit_limit — ONEC-047,
        // GQ-CRD-10): шаги 1–2 повторяются по свежей карточке, а не по прочитанной до обновления (ревью G-credit-1).
        const fresh = { ...base, customer: toCreditCustomer(await this.customers.load(tx, customerId)) };
        d = await decide(fresh, 'refreshed');
      }
    }
    return this.result(d, input);
  }

  private result(d: CreditDecision, input: CreditCheckInput): CreditCheckResult {
    if (d.kind === 'allowed') {
      return {
        allowed: true,
        overrideUsed: d.overrideUsed,
        limitRemaining: d.limitRemaining === null ? null : d.limitRemaining.toString(),
        receivablesAsOf: d.receivablesAsOf,
      };
    }
    // `refresh_required` после попытки обновления не возвращается `decideCredit` (передан исход `refresh`).
    const r = d as Extract<CreditDecision, { kind: 'refused' }>;
    this.logger.debug(
      {
        event: 'credit.refused',
        code: r.code,
        creditReason: r.creditReason,
        step: r.step,
        customerId: input.customerId,
      },
      'credit: отказ в продаже в долг',
    );
    return {
      allowed: false,
      code: r.code,
      creditReason: r.creditReason,
      detail: r.detail,
      ...(r.limitRemaining !== undefined
        ? { limitRemaining: r.limitRemaining === null ? null : r.limitRemaining.toString() }
        : {}),
      ...(r.receivablesAsOf !== undefined ? { receivablesAsOf: r.receivablesAsOf } : {}),
    };
  }
}
