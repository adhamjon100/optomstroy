import { createHash } from 'node:crypto';
import type { SyncEntity } from '../../common/enums.js';
import { percentToHundredths } from '../../sales-domain/pricing/percent.js';
import { type ApplyScope, type ChangeItemHandler, emptyCounts, type EntityCounts } from '../apply/apply.types.js';

/** Тип элемента плана обмена «Скидки (наценки)» (05 §5.3, ONEC-008; контракт 1С `DiscountChange`). */
export const DISCOUNT_RULE_TYPE = 'Catalog_СкидкиНаценки';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DECIMAL_RE = /^\d{1,12}(\.\d{1,2})?$/;
const DATE_RE = /^(\d{4}-\d{2}-\d{2})(T.*)?$/;
const KINDS = ['percent', 'fixed_amount', 'price_list'] as const;

type Item = Readonly<Record<string, unknown>>;

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v !== null && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(v ?? null);
}

function dateOrNull(v: unknown): string | null {
  const m = typeof v === 'string' ? DATE_RE.exec(v) : null;
  return m ? m[1] : null;
}

export interface DiscountRuleFields {
  readonly kind: (typeof KINDS)[number];
  readonly value: string;
  readonly isActive: boolean;
  readonly appliesAutomatically: boolean;
  readonly validFrom: string | null;
  readonly validTo: string | null;
  readonly minTotal: string | null;
  readonly partnerRefs: readonly string[];
}

/**
 * Поля правила из элемента `/changes`. Контракт 1С передаёт только `code`/`description`/`deletionMark`; параметры —
 * поля-предложения GQ-FND-05 (`kind`, `value`, `isActive`, `appliesAutomatically`, `validFrom`, `validTo`,
 * `conditions{minTotal, partnerRefs}`). Без них (строгий контракт) — рекомендация GQ-FND-05: `kind=percent`,
 * `value=0`, `is_active = NOT deletionMark`, показ только названия. Ошибка значения → `null` (позиция в `sync_errors`).
 */
export function discountRuleFields(it: Item): DiscountRuleFields | { error: string } {
  const deletion = it.deletionMark === true;
  const kind = it.kind === undefined || it.kind === null ? 'percent' : it.kind;
  if (!KINDS.includes(kind as (typeof KINDS)[number])) return { error: `неизвестный kind ${JSON.stringify(kind)}` };
  const value = it.value === undefined || it.value === null ? '0' : it.value;
  if (typeof value !== 'string' || !DECIMAL_RE.test(value)) return { error: 'value — ожидается неотрицательная сумма' };
  if (kind === 'percent') {
    try {
      percentToHundredths(value);
    } catch {
      return { error: 'value — процент больше 100' };
    }
  }
  const cond =
    it.conditions !== null && typeof it.conditions === 'object' ? (it.conditions as Record<string, unknown>) : {};
  const minTotal = typeof cond.minTotal === 'string' && /^\d{1,12}\.\d{2}$/.test(cond.minTotal) ? cond.minTotal : null;
  const partnerRefs = Array.isArray(cond.partnerRefs)
    ? cond.partnerRefs.filter((x): x is string => typeof x === 'string' && UUID_RE.test(x)).map((x) => x.toLowerCase())
    : [];
  return {
    kind: kind as (typeof KINDS)[number],
    value,
    isActive: !deletion && (typeof it.isActive === 'boolean' ? it.isActive : true),
    appliesAutomatically: it.appliesAutomatically === true,
    validFrom: dateOrNull(it.validFrom),
    validTo: dateOrNull(it.validTo),
    minTotal,
    partnerRefs,
  };
}

function countsOf(scope: ApplyScope): EntityCounts {
  let c = scope.counts.get('discounts');
  if (!c) {
    c = { ...emptyCounts(), tables: {} };
    scope.counts.set('discounts', c);
  }
  return c;
}

/**
 * Обработчик элементов `/changes` `Catalog_СкидкиНаценки` и их `ObjectDeletion` → `discount_rules` (`source=onec`;
 * 07 §5.33; 05 SYNC-001 сущность `discounts`; RM-G-003). Выполняется в транзакции сообщения плана обмена:
 *
 * - upsert по `onec_ref`; неизменённый элемент (`source_hash`) не перезаписывается (05 SYNC-013);
 * - `conditions.customerIds` — клиенты POS по `partnerRefs` (ref партнёров 1С), найденные на момент применения;
 *   сами `partnerRefs` сохраняются в `conditions` — применимость к клиенту, пришедшему позже, проверяется по ref
 *   (`DiscountPolicyService`);
 * - пометка удаления → `deletion_mark = true`, `is_active = false`; `ObjectDeletion` — то же (физически правило не
 *   удаляется: на него ссылаются заказы, `orders.discount_rule_id`).
 */
export class DiscountRulesChangeHandler implements ChangeItemHandler {
  readonly types: readonly string[] = [DISCOUNT_RULE_TYPE];

  entityOf(_item: Item): SyncEntity | undefined {
    return 'discounts';
  }

  async apply(scope: ApplyScope, items: readonly Item[]): Promise<void> {
    const counts = countsOf(scope);
    await scope.runIdFor('discounts');
    for (const it of items) {
      counts.fetched += 1;
      const ref = typeof it.ref === 'string' && UUID_RE.test(it.ref) ? it.ref.toLowerCase() : null;
      if (ref === null) {
        this.error(scope, counts, it, 'ref — ожидается UUID');
        continue;
      }
      if (it.type === 'ObjectDeletion') {
        const r = await scope.client.query(
          `UPDATE discount_rules SET deletion_mark = true, is_active = false, synced_at = $2,
                  row_version = row_version + 1, updated_at = now()
            WHERE onec_ref = $1::uuid AND source = 'onec' AND NOT (deletion_mark AND NOT is_active)`,
          [ref, scope.syncedAt],
        );
        counts.markedDeleted += r.rowCount ?? 0;
        continue;
      }
      const f = discountRuleFields(it);
      if ('error' in f) {
        this.error(scope, counts, it, f.error, ref);
        continue;
      }
      const description = typeof it.description === 'string' && it.description.trim() !== '' ? it.description : null;
      if (description === null) {
        this.error(scope, counts, it, 'description — пусто', ref);
        continue;
      }
      const hash = createHash('sha256').update(canonical(it)).digest('hex');
      const customerIds =
        f.partnerRefs.length === 0
          ? []
          : (
              await scope.client.query<{ id: string }>(
                `SELECT id FROM customers WHERE onec_ref = ANY($1::uuid[]) ORDER BY id`,
                [f.partnerRefs],
              )
            ).rows.map((r) => r.id);
      const conditions = {
        ...(f.minTotal !== null ? { minTotal: f.minTotal } : {}),
        ...(f.partnerRefs.length > 0 ? { customerIds, partnerRefs: f.partnerRefs } : {}),
      };
      const r = await scope.client.query<{ inserted: boolean }>(
        `INSERT INTO discount_rules (onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash, source,
                                     name, kind, value, conditions, applies_automatically, is_active, valid_from,
                                     valid_to, description_ru)
         VALUES ($1::uuid, $2, $3, $4, $5, $6, 'onec', $7, $8::discount_kind, $9::numeric, $10::jsonb, $11, $12,
                 $13::date, $14::date, $7)
         ON CONFLICT (onec_ref) WHERE onec_ref IS NOT NULL DO UPDATE
            SET onec_code = EXCLUDED.onec_code, onec_data_version = EXCLUDED.onec_data_version,
                deletion_mark = EXCLUDED.deletion_mark, synced_at = EXCLUDED.synced_at,
                source_hash = EXCLUDED.source_hash, name = EXCLUDED.name, kind = EXCLUDED.kind,
                value = EXCLUDED.value, conditions = EXCLUDED.conditions,
                applies_automatically = EXCLUDED.applies_automatically, is_active = EXCLUDED.is_active,
                valid_from = EXCLUDED.valid_from, valid_to = EXCLUDED.valid_to,
                description_ru = EXCLUDED.description_ru, row_version = discount_rules.row_version + 1,
                updated_at = now()
          WHERE discount_rules.source_hash IS DISTINCT FROM EXCLUDED.source_hash
             OR discount_rules.conditions IS DISTINCT FROM EXCLUDED.conditions
         RETURNING (xmax = 0) AS inserted`,
        [
          ref,
          typeof it.code === 'string' ? it.code : null,
          typeof it.dataVersion === 'string' ? it.dataVersion : null,
          it.deletionMark === true,
          scope.syncedAt,
          hash,
          description,
          f.kind,
          f.value,
          JSON.stringify(conditions),
          f.appliesAutomatically,
          f.isActive,
          f.validFrom,
          f.validTo,
        ],
      );
      const row = r.rows[0];
      if (!row) counts.skipped += 1;
      else if (row.inserted) counts.inserted += 1;
      else counts.updated += 1;
    }
  }

  private error(scope: ApplyScope, counts: EntityCounts, it: Item, message: string, ref?: string): void {
    counts.errors += 1;
    scope.errors.push({
      entity: 'discounts',
      errorCode: 'VALIDATION',
      severity: 'warning',
      message: `скидка 1С: ${message}`,
      onecRef: ref ?? null,
      onecCode: typeof it.code === 'string' ? it.code : null,
    });
  }
}
