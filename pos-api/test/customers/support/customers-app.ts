import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { sql } from 'drizzle-orm';
import pino from 'pino';
import YAML from 'yaml';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../../src/common/jobs/contracts/queues.js';
import {
  RECEIVABLES_SNAPSHOT_PORT,
  type ReceivablesSnapshotPort,
  type ReceivablesSnapshotView,
} from '../../../src/common/ports/index.js';
import { CustomersModule } from '../../../src/customers/customers.module.js';
import { CustomerOnecResultsHandler } from '../../../src/customers/jobs/customer-onec-results.handler.js';
import { OutboxDispatcher } from '../../../src/jobs/outbox/outbox-dispatcher.js';
import { OnecOutboxDelivery } from '../../../src/sync/outbox/onec-outbox.delivery.js';
import { schedulerConfigFromEnv } from '../../../src/sync/scheduler/scheduler.config.js';
import { CashierTestApp } from '../../support/cashier-fixture.js';
import type { PosFixtureOptions } from '../../support/pos-fixture.js';

/**
 * Стенд RM-G-001 (агент G-be-customers) — **тестовые данные**: `CashierTestApp` (embedded PostgreSQL 17, синтетический
 * каталог, фейк 1С в режиме кассира) с модулем `customers` целиком (поиск, история, список, карточка, создание,
 * избранные клиенты, порт `CUSTOMER_READER`). Модули F не подключаются: маршруты клиентов не зависят от них (заказы
 * POS сидируются напрямую `seedOrder`). Воркер outbox — `OutboxDispatcher` + `OnecOutboxDelivery` над фейком 1С,
 * события результата перехватываются и применяются `CustomerOnecResultsHandler` (как `pos-worker`).
 */
export class CustomersTestApp extends CashierTestApp {
  readonly published: { name: string; data: Record<string, unknown> }[] = [];
  dispatcher!: OutboxDispatcher;
  results!: CustomerOnecResultsHandler;
  private handled = 0;

  override async start(opts: PosFixtureOptions = {}): Promise<this> {
    await super.start({ jobs: false, ...opts, modules: opts.modules ?? [CustomersModule] });
    const log = pino({ level: 'silent' });
    this.results = new CustomerOnecResultsHandler(this.db, log);
    const cfg = schedulerConfigFromEnv(this.config, {}).outbox;
    this.dispatcher = new OutboxDispatcher(
      this.pool,
      new OnecOutboxDelivery(this.onec, { timeoutMs: 2_000 }),
      {
        send: (name: string, data: object) => {
          this.published.push({ name, data: data as Record<string, unknown> });
          return Promise.resolve(randomUUID());
        },
      },
      cfg,
      'test-customers-worker',
      log,
    );
    if (!this.registry.isBound(RECEIVABLES_SNAPSHOT_PORT)) {
      // Реализация порта — агент G-be-credit; до её привязки — чтение снимка из таблицы `receivables`.
      this.replacePort(RECEIVABLES_SNAPSHOT_PORT, new DbReceivablesSnapshots(this));
    }
    return this;
  }

  /** Тик диспетчера outbox + применение опубликованных `customers.onec-*` (как pos-worker). */
  async drainOutbox(): Promise<void> {
    await this.pool.query(
      `UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`,
    );
    await this.dispatcher.tick();
    while (this.handled < this.published.length) {
      const p = this.published[this.handled++];
      if (p.name === 'customers.onec-confirmed')
        await this.results.onConfirmed(p.data as unknown as OnecConfirmedPayload);
      if (p.name === 'customers.onec-failed') await this.results.onFailed(p.data as unknown as OnecFailedPayload);
    }
  }

  async customerRow(id: string) {
    return (
      await this.q<{
        id: string;
        source: string;
        onec_status: string;
        onec_ref: string | null;
        onec_code: string | null;
        name: string;
        deletion_mark: boolean;
        credit_limit: string | null;
        primary_phone_e164: string | null;
        phones_norm: string[];
        inn: string | null;
        customer_type: string;
        force_reason: string | null;
      }>(
        `SELECT id, source::text AS source, onec_status::text AS onec_status, onec_ref::text AS onec_ref, onec_code,
                name, deletion_mark, credit_limit::text AS credit_limit, primary_phone_e164, phones_norm, inn,
                customer_type::text AS customer_type, force_reason
           FROM customers WHERE id = $1::uuid`,
        [id],
      )
    )[0];
  }
}

/** Чтение снимка долга из `receivables` (заглушка до привязки порта агентом G-be-credit; только тесты). */
class DbReceivablesSnapshots implements ReceivablesSnapshotPort {
  constructor(private readonly t: CashierTestApp) {}

  maxAgeMinutes(): Promise<number> {
    return Promise.resolve(60);
  }

  async snapshot(_tx: unknown, customerId: string, now: Date = new Date()): Promise<ReceivablesSnapshotView | null> {
    const r = (
      await this.t.db.execute<{
        balance: string;
        overdue_amount: string | null;
        overdue_days: number | null;
        oldest: string | null;
        at: Date;
      }>(sql`SELECT balance::text AS balance, overdue_amount::text AS overdue_amount, overdue_days,
                    oldest_due_date::text AS oldest, onec_snapshot_at AS at
               FROM receivables WHERE customer_id = ${customerId}::uuid`)
    ).rows[0];
    if (!r) return null;
    const at = new Date(r.at);
    const ageMinutes = Math.max(0, Math.floor((now.getTime() - at.getTime()) / 60_000));
    return {
      customerId,
      balance: r.balance,
      overdueAmount: r.overdue_amount,
      overdueDays: r.overdue_days,
      oldestDueDate: r.oldest,
      snapshotAt: at,
      ageMinutes,
      isStale: ageMinutes > 60,
      usableForCredit: ageMinutes <= 60 && r.overdue_amount !== null,
      maxAgeMinutes: 60,
    };
  }

  documents(): Promise<never[]> {
    return Promise.resolve([]);
  }

  openOrdersAmount(): Promise<string> {
    return Promise.resolve('0.00');
  }

  refresh(): Promise<{ kind: 'not_in_onec' }> {
    return Promise.resolve({ kind: 'not_in_onec' });
  }
}

// -------------------------------------------------------------------------------------- контракт OpenAPI 1.2.0

const POS_API = fileURLToPath(new URL('../../../../contracts/openapi/pos-api.v1.yaml', import.meta.url));
type Schema = Record<string, unknown>;
let cached: Record<string, Schema> | undefined;

export function apiSchemas(): Record<string, Schema> {
  if (!cached) {
    const doc = YAML.parse(readFileSync(POS_API, 'utf8')) as { components: { schemas: Record<string, Schema> } };
    cached = doc.components.schemas;
  }
  return cached;
}

function resolve(s: Schema): Schema {
  const ref = s.$ref;
  if (typeof ref !== 'string') return s;
  const target = apiSchemas()[ref.split('/').pop()!];
  if (!target) throw new Error(`нет схемы ${ref}`);
  return resolve(target);
}

function typeOf(v: unknown): string {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v;
}

function check(value: unknown, schema: Schema, path: string, errors: string[]): void {
  const s = resolve(schema);
  if (value === null) {
    const nullable = s.nullable === true || (Array.isArray(s.allOf) && s.nullable === true);
    if (!nullable) errors.push(`${path}: null не допускается`);
    return;
  }
  if (Array.isArray(s.allOf)) for (const part of s.allOf as Schema[]) check(value, part, path, errors);
  const t = s.type as string | undefined;
  const actual = typeOf(value);
  if (t && !(t === actual || (t === 'number' && actual === 'integer'))) {
    errors.push(`${path}: тип ${actual}, ожидался ${t}`);
    return;
  }
  if (Array.isArray(s.enum) && !(s.enum as unknown[]).includes(value))
    errors.push(`${path}: ${JSON.stringify(value)} не в enum`);
  if (typeof s.pattern === 'string' && typeof value === 'string' && !new RegExp(s.pattern).test(value)) {
    errors.push(`${path}: "${value}" не соответствует ${s.pattern}`);
  }
  if (s.format === 'uuid' && typeof value === 'string' && !/^[0-9a-f-]{36}$/i.test(value))
    errors.push(`${path}: не uuid`);
  if (s.format === 'date-time' && typeof value === 'string' && !Number.isFinite(Date.parse(value))) {
    errors.push(`${path}: не date-time`);
  }
  if (typeof s.minimum === 'number' && typeof value === 'number' && value < s.minimum)
    errors.push(`${path}: < minimum`);
  if (actual === 'array' && s.items)
    (value as unknown[]).forEach((x, i) => check(x, s.items as Schema, `${path}[${i}]`, errors));
  if (actual === 'object') {
    const obj = value as Record<string, unknown>;
    for (const r of (s.required as string[] | undefined) ?? [])
      if (!(r in obj)) errors.push(`${path}.${r}: отсутствует`);
    const props = (s.properties as Record<string, Schema> | undefined) ?? {};
    for (const [k, ps] of Object.entries(props)) if (k in obj) check(obj[k], ps, `${path}.${k}`, errors);
    if (s.additionalProperties === false) {
      for (const k of Object.keys(obj)) if (!(k in props)) errors.push(`${path}.${k}: поле вне allowlist`);
    }
  }
}

/** Ошибки соответствия значения схеме `components.schemas.<name>` OpenAPI POS API (пусто — соответствует). */
export function apiErrors(name: string, value: unknown): string[] {
  const errors: string[] = [];
  check(value, { $ref: `#/components/schemas/${name}` }, name, errors);
  return errors;
}

/** Ролевое представление `Customer` по роли (08 §3.7): строгие схемы с `additionalProperties: false`. */
export function viewSchemaFor(role: string): string {
  if (role === 'seller') return 'CustomerViewSeller';
  if (role === 'cashier' || role === 'senior_seller') return 'CustomerViewCashier';
  if (role === 'customer') return 'CustomerViewSelf';
  return 'CustomerViewAdmin';
}
