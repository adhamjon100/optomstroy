import { sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import type pg from 'pg';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { SyncEntity } from '../../common/enums.js';
import { transactionDedupeKey, transactionJournal } from '../../common/journal/index.js';
import { Money, Quantity } from '../../common/money/money.js';
import type { NotificationsPort } from '../../common/ports/index.js';
import * as schema from '../../db/schema/index.js';
import { NotificationsRepository } from '../../notifications/center/notifications.repository.js';
import { NotificationsPortService } from '../../notifications/center/notifications-port.service.js';
import { type ApplyScope, type ChangeItemHandler, emptyCounts } from '../../sync/apply/apply.types.js';
import { ReturnsRepository } from '../returns.repository.js';
import { ReturnOnecProjector } from './return-onec-projector.js';

export const RETURN_DOC_TYPE = 'Document_ВозвратТоваровОтКлиента';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MONEY_RE = /^-?\d+\.\d{2}$/;
const QTY_RE = /^-?\d+\.\d{3}$/;

function str(v: unknown): string | null {
  return typeof v === 'string' && v !== '' ? v : null;
}

interface DocLine {
  readonly productRef: string | null;
  readonly variantRef: string | null;
  readonly quantity: string;
}

function docLines(v: unknown): DocLine[] {
  if (!Array.isArray(v)) return [];
  return v
    .filter((l): l is Record<string, unknown> => typeof l === 'object' && l !== null)
    .map((l) => ({
      productRef: str(l.productRef),
      variantRef: str(l.variantRef),
      quantity: typeof l.quantity === 'string' && QTY_RE.test(l.quantity) ? l.quantity : '0.000',
    }));
}

const key = (productRef: string | null, variantRef: string | null) => `${productRef ?? '-'}|${variantRef ?? '-'}`;

/**
 * Проекция документов «Возврат товаров от клиента» 1С (`/changes`, тип `Document_ВозвратТоваровОтКлиента`; прогон
 * `return_docs` — ядро §17.3; 05 ONEC-015, SYNC-018, SYNC-050; 10 RET-006, RET-007, TXN-007):
 * - проведённый документ → **единственная** строка журнала `transactions.kind=refund` (`source='onec'`, без актора,
 *   сумма `−total`, идемпотентно по `onec_ref` — `transactionDedupeKey.onecDocument`); приложение `refund` не создаёт;
 * - строка связывается с заявкой POS (`return_request_id`) той же реализации в статусе `accepted`/`submitted`, если
 *   документ покрывает её строки (по товару/характеристике — в строках документа возврата номера строки реализации нет,
 *   GQ-TXR-06); покрытие всех строк → `completed` (через `accepted`, автомат ядра §22.11), автору — уведомление;
 * - непроведённый или помеченный на удаление документ строку не создаёт (пересборка журнала — GQ-TXR-06).
 * Количества возвращённого по строкам реализации (`shipment_items.returned_quantity`) обновляет проекция
 * `sales_history` (модуль customers) — здесь не пишутся.
 */
export class ReturnDocsChangeHandler implements ChangeItemHandler {
  readonly types = [RETURN_DOC_TYPE] as const;
  private readonly repo = new ReturnsRepository();

  constructor(
    private readonly opts: {
      /** Порт уведомлений процесса; по умолчанию — реализация модуля notifications над соединением прогона. */
      readonly notifications?: NotificationsPort | null;
      readonly log?: { warn(o: Record<string, unknown>, m: string): void };
    } = {},
  ) {}

  entityOf(): SyncEntity {
    return 'return_docs';
  }

  async apply(scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void> {
    const db = drizzle({ client: scope.client as unknown as pg.Pool, schema }) as unknown as DbExecutor;
    const notifications =
      this.opts.notifications !== undefined
        ? this.opts.notifications
        : new NotificationsPortService(new NotificationsRepository(db));
    const projector = new ReturnOnecProjector(notifications, this.opts.log ?? { warn: () => undefined });
    const counts = scope.counts.get('return_docs') ?? { ...emptyCounts(), tables: {} };
    scope.counts.set('return_docs', counts);
    for (const it of items) {
      counts.fetched += 1;
      const ref = str(it.ref);
      if (!ref || !UUID_RE.test(ref)) {
        counts.errors += 1;
        scope.errors.push({
          entity: 'return_docs',
          errorCode: 'VALIDATION',
          message: 'Документ возврата без ссылки',
          severity: 'warning',
        });
        continue;
      }
      if (it.deletionMark === true || it.posted !== true) {
        counts.skipped += 1;
        continue;
      }
      const shipmentRef = str(it.shipmentRef);
      const ship = shipmentRef
        ? (
            await db.execute<{ id: string; customer_id: string; order_id: string | null }>(
              sql`SELECT id, customer_id, order_id FROM shipments
                WHERE onec_ref = ${shipmentRef}::uuid`,
            )
          ).rows[0]
        : undefined;
      if (!ship) {
        counts.errors += 1;
        scope.errors.push({
          entity: 'return_docs',
          errorCode: 'NOT_FOUND_LOCAL',
          message: 'Реализация документа возврата не найдена в реплике',
          severity: 'warning',
          onecRef: ref,
          payload: { shipmentRef },
        });
        continue;
      }
      // Повторная доставка того же документа (перепроведение/изменение в 1С, повтор пакета /changes): строка refund уже
      // есть — заявка заново не подбирается и не проецируется (идемпотентность по onec_ref: 05 ONEC-015, SYNC-031,
      // 10 TXN-005; ревью G-returns-txn-1).
      const dedupeKey = transactionDedupeKey.onecDocument('refund', ref);
      const seen = await db.execute<{ id: string }>(sql`SELECT id FROM transactions WHERE dedupe_key = ${dedupeKey}`);
      if (seen.rows[0]) {
        counts.skipped += 1;
        continue;
      }
      const lines = docLines(it.lines);
      const match = await this.matchRequest(db, ship.id, lines);
      const totalRaw = typeof it.total === 'string' && MONEY_RE.test(it.total) ? it.total : null;
      const total = totalRaw ? Money.of(totalRaw).toString().replace(/^-/, '') : '0.00';
      const date = str(it.date);
      const res = await transactionJournal.record(db, {
        kind: 'refund',
        source: 'onec',
        orderId: ship.order_id,
        shipmentId: ship.id,
        returnRequestId: match?.id ?? null,
        customerId: ship.customer_id,
        actorUserId: null,
        amount: Money.ZERO.minus(Money.of(total)).toString(),
        paymentMethod: null,
        statusSnapshot: 'posted',
        title: `Возврат товаров от клиента ${str(it.number) ?? ''}`.trim(),
        details: { number: str(it.number), shipmentRef, returnRequest: match?.publicNumber ?? null },
        occurredAt: date && !Number.isNaN(Date.parse(date)) ? new Date(date) : null,
        onecRef: ref,
        onecNumber: str(it.number),
        onecDocType: RETURN_DOC_TYPE,
        dedupeKey,
      });
      if (res.created) counts.inserted += 1;
      else counts.skipped += 1;
      if (match?.covered) {
        const r = await this.repo.findById(db, match.id, true);
        if (r) await projector.apply(db, r, { status: 'completed', onecStatus: null }, 'return_docs');
      }
    }
  }

  /**
   * Заявка той же реализации (`accepted` раньше `submitted`, старшие первыми), чьи строки покрывает документ:
   * Σ количества документа по товару/характеристике ≥ количества строки заявки.
   */
  private async matchRequest(
    db: DbExecutor,
    shipmentId: string,
    lines: readonly DocLine[],
  ): Promise<{ id: string; publicNumber: string; covered: boolean } | null> {
    const rows = await db.execute<{
      id: string;
      public_number: string;
      quantity: string;
      product_ref: string | null;
      variant_ref: string | null;
    }>(sql`
      SELECT r.id, r.public_number, i.quantity::text AS quantity, p.onec_ref::text AS product_ref,
             CASE WHEN v.is_default THEN NULL ELSE v.onec_ref::text END AS variant_ref
        FROM return_requests r
        JOIN return_request_items i ON i.return_request_id = r.id
        LEFT JOIN product_variants v ON v.id = i.variant_id
        LEFT JOIN products p ON p.id = v.product_id
       WHERE r.shipment_id = ${shipmentId}::uuid AND r.status IN ('accepted','submitted')
         -- Заявка, уже связанная с другим документом возврата 1С (строка refund), повторно не подбирается.
         AND NOT EXISTS (SELECT 1 FROM transactions t WHERE t.return_request_id = r.id AND t.kind = 'refund')
       ORDER BY (r.status = 'accepted') DESC, r.submitted_at NULLS LAST, r.id`);
    if (rows.rows.length === 0) return null;
    const have = new Map<string, bigint>();
    for (const l of lines) {
      const k = key(l.productRef, l.variantRef);
      have.set(k, (have.get(k) ?? 0n) + Quantity.of(l.quantity.replace(/^-/, '')).toMilli());
    }
    const byRequest = new Map<string, { publicNumber: string; need: Map<string, bigint> }>();
    for (const r of rows.rows) {
      const e = byRequest.get(r.id) ?? { publicNumber: r.public_number, need: new Map<string, bigint>() };
      const k = key(r.product_ref, r.variant_ref);
      e.need.set(k, (e.need.get(k) ?? 0n) + Quantity.of(r.quantity).toMilli());
      byRequest.set(r.id, e);
    }
    let firstPartial: { id: string; publicNumber: string } | null = null;
    for (const [id, e] of byRequest) {
      const keys = [...e.need.keys()];
      const covered = keys.every((k) => (have.get(k) ?? 0n) >= (e.need.get(k) ?? 0n));
      if (covered) return { id, publicNumber: e.publicNumber, covered: true };
      if (!firstPartial && keys.some((k) => (have.get(k) ?? 0n) > 0n))
        firstPartial = { id, publicNumber: e.publicNumber };
    }
    return firstPartial ? { ...firstPartial, covered: false } : null;
  }
}
