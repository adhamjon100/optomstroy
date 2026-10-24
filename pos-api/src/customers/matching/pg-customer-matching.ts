import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { ONEC_GATEWAY, type OnecGateway, type OnecJsonObject } from '../../integrations/onec/onec-gateway.js';
import {
  type CustomerMatching,
  type CustomerMatchResult,
  type FindByPhoneOptions,
  KG_E164,
  type MatchCandidate,
  type OnecLookupState,
} from './customer-matching.port.js';

interface ReplicaRow extends Record<string, unknown> {
  id: string;
  onec_ref: string | null;
  is_primary: boolean;
  /**
   * POS-клиент без `onec_ref`, чей `customer/create` уже отправляется в 1С (`sending` или повтор после попытки с
   * неизвестным исходом): карточка 1С с этим телефоном может быть им самим (ревью G-customers-1c-2).
   */
  onec_in_flight: boolean;
}

/** Кандидат 1С по контракту `CustomerCandidate` (contracts/onec/onec-http-service.v1.yaml, 18 §4.8). */
interface OnecCandidate {
  readonly ref: string;
  readonly contractorRef: string | null;
  readonly code: string | null;
  readonly name: string;
  readonly phone: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Последние 9 цифр номера — правило сравнения 1С (ONEC-044: `0700123456` и `+996700123456` — один номер). */
function last9(phone: string): string {
  return phone.replace(/\D/g, '').slice(-9);
}

function parseOnecCandidate(raw: OnecJsonObject): OnecCandidate | undefined {
  const { ref, contractorRef, code, name, phone, deletionMark } = raw;
  if (typeof ref !== 'string' || !UUID_RE.test(ref)) return undefined;
  if (typeof name !== 'string' || typeof phone !== 'string') return undefined;
  if (deletionMark === true) return undefined;
  return {
    ref: ref.toLowerCase(),
    contractorRef:
      typeof contractorRef === 'string' && UUID_RE.test(contractorRef) ? contractorRef.toLowerCase() : null,
    code: typeof code === 'string' && code.trim() !== '' ? code.trim() : null,
    name,
    phone,
  };
}

/** Наименование для CHECK `customers_name_chk` (2…200 символов). */
function replicaName(name: string): string {
  const t = name.trim().slice(0, 200);
  return t.length >= 2 ? t : `${t}__`.slice(0, 2);
}

/**
 * Реализация `CustomerMatching` (RM-D-005) поверх PostgreSQL-реплики и необязательного порта 1С.
 *
 * Реплика: живые карточки (`deleted_at IS NULL`, `deletion_mark = false`, кроме «Розничного покупателя»), у которых
 * телефон — основной (`primary_phone_e164`), входит в `phones_norm` или в живые контакты `customer_contacts`
 * (`kind = phone`, `value_norm`). Признак `primary` — основной телефон карточки или контакт `is_primary`.
 *
 * 1С: кандидаты `findCustomersByPhone` (таймаут `ONEC_SYNC_CHECK_TIMEOUT_MS`) с совпадением последних 9 цифр и без пометки удаления. Карточка, уже
 * известная реплике (`onec_ref`), объединяется с ней; неизвестная — добавляется в реплику строкой
 * `source = onec` по данным ответа (`INSERT … ON CONFLICT DO NOTHING`, `synced_at`/`source_hash` пустые — полную
 * карточку перезапишет синхронизация `customers`, 07 §5.28 «писатели столбцов»). Тип такой строки неизвестен
 * (поиск 1С его не возвращает) — ставится консервативно `legal`: самоподтверждение по ней невозможно, решает
 * `admin` (11 SEC-130). См. docs/stages/D_spec_questions.md (раздел RM-D-005/RM-D-015).
 */
@Injectable()
export class PgCustomerMatching implements CustomerMatching {
  private readonly logger = new Logger('CustomerMatching');

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'ONEC_SYNC_CHECK_TIMEOUT_MS'>,
    @Optional() @Inject(ONEC_GATEWAY) private readonly onec?: OnecGateway,
  ) {}

  async findByPhone(phoneE164: string, options: FindByPhoneOptions = {}): Promise<CustomerMatchResult> {
    if (!KG_E164.test(phoneE164)) throw new RangeError('CustomerMatching: телефон — E.164 +996XXXXXXXXX');
    const ex = options.executor ?? this.db;
    const replica = await this.searchReplica(phoneE164, ex);
    const byId = new Map<string, MatchCandidate>();
    for (const r of replica) {
      byId.set(r.id, { customerId: r.id, matchKind: r.is_primary ? 'primary' : 'secondary', onecRef: r.onec_ref });
    }

    let onecState: OnecLookupState = 'disabled';
    if (this.onec && options.useOnec !== false) {
      const found = await this.searchOnec(phoneE164, options.requestId);
      onecState = found === undefined ? 'unavailable' : 'ok';
      const inFlight = replica.some((r) => r.onec_in_flight);
      for (const c of found ?? []) {
        const known = [...byId.values()].find((m) => m.onecRef === c.ref);
        if (known) continue;
        // Ref — карточка, которую 1С создала по `customer/create` POS-клиента (результат ещё не применён): это он
        // сам, заглушка реплики не создаётся (05 SYNC-005: сопоставление только по externalId; ревью G-customers-1c-2).
        const own = await ex.execute<{ id: string }>(sql`
          SELECT x.aggregate_id AS id FROM onec_outbox x JOIN customers p ON p.id = x.aggregate_id
           WHERE x.aggregate_type = 'customer' AND x.operation = 'create' AND x.onec_ref = ${c.ref}::uuid
             AND p.deleted_at IS NULL AND p.onec_ref IS NULL
           LIMIT 1`);
        const ownId = own.rows[0]?.id;
        if (ownId) {
          if (!byId.has(ownId)) byId.set(ownId, { customerId: ownId, matchKind: 'onec', onecRef: null });
          continue;
        }
        if (inFlight) continue;
        const id = await this.ensureReplicaRow(c, phoneE164, ex);
        if (id && !byId.has(id)) byId.set(id, { customerId: id, matchKind: 'onec', onecRef: c.ref });
      }
    }

    const order: Record<MatchCandidate['matchKind'], number> = { primary: 0, secondary: 1, onec: 2 };
    const candidates = [...byId.values()].sort(
      (a, b) => order[a.matchKind] - order[b.matchKind] || a.customerId.localeCompare(b.customerId),
    );
    return { candidates, onec: onecState };
  }

  private async searchReplica(phone: string, ex: DbExecutor): Promise<ReplicaRow[]> {
    const res = await ex.execute<ReplicaRow>(sql`
      SELECT c.id, c.onec_ref,
             (c.primary_phone_e164 = ${phone}
              OR EXISTS (SELECT 1 FROM customer_contacts p
                          WHERE p.customer_id = c.id AND p.kind = 'phone' AND p.is_primary
                            AND p.value_norm = ${phone} AND p.deleted_at IS NULL)) AS is_primary,
             (c.source = 'pos' AND c.onec_ref IS NULL AND c.onec_status = 'pending'
              AND EXISTS (SELECT 1 FROM onec_outbox x
                           WHERE x.aggregate_type = 'customer' AND x.operation = 'create' AND x.aggregate_id = c.id
                             AND (x.status = 'sending' OR (x.status = 'pending' AND x.attempts > 0)))) AS onec_in_flight
        FROM customers c
       WHERE c.deleted_at IS NULL
         AND c.deletion_mark = false
         AND c.is_retail_default = false
         AND (c.primary_phone_e164 = ${phone}
              OR ${phone} = ANY (c.phones_norm)
              OR EXISTS (SELECT 1 FROM customer_contacts cc
                          WHERE cc.customer_id = c.id AND cc.kind = 'phone'
                            AND cc.value_norm = ${phone} AND cc.deleted_at IS NULL))
       ORDER BY c.id`);
    return res.rows;
  }

  /** `undefined` — 1С недоступна (ошибка, таймаут); `[]` — 1С ответила «не найдено». */
  private async searchOnec(phone: string, requestId: string | undefined): Promise<OnecCandidate[] | undefined> {
    if (!this.onec) return undefined;
    try {
      const res = await this.onec.findCustomersByPhone(phone, {
        // Синхронный вызов при работе кассира/регистрации — общий таймаут `ONEC_SYNC_CHECK_TIMEOUT_MS` (6 с, ТЗ 4.9).
        signal: AbortSignal.timeout(this.config.ONEC_SYNC_CHECK_TIMEOUT_MS),
        ...(requestId ? { requestId } : {}),
      });
      const want = last9(phone);
      const out: OnecCandidate[] = [];
      for (const raw of Array.isArray(res.body) ? res.body : []) {
        const c = parseOnecCandidate(raw);
        if (c && last9(c.phone) === want && !out.some((o) => o.ref === c.ref)) out.push(c);
      }
      return out;
    } catch (e) {
      // Телефон в журнал не пишется (AC-ONEC-088); только класс ошибки.
      this.logger.warn(
        { event: 'customer_match.onec_unavailable', err: e instanceof Error ? e.name : 'unknown' },
        'customer match: 1C unavailable, replica only',
      );
      return undefined;
    }
  }

  private async ensureReplicaRow(c: OnecCandidate, phone: string, ex: DbExecutor): Promise<string | undefined> {
    await ex.execute(sql`
      INSERT INTO customers (onec_ref, onec_code, onec_counterparty_ref, source, name, customer_type,
                             primary_phone_e164, phones_norm, onec_status)
      VALUES (${c.ref}::uuid, ${c.code}, ${c.contractorRef}::uuid, 'onec', ${replicaName(c.name)}, 'legal',
              ${phone}, ARRAY[${phone}]::text[], 'n_a')
      ON CONFLICT DO NOTHING`);
    const res = await ex.execute<{ id: string; deleted: boolean }>(sql`
      SELECT id, (deleted_at IS NOT NULL OR deletion_mark) AS deleted FROM customers WHERE onec_ref = ${c.ref}::uuid`);
    const row = res.rows[0];
    return row && !row.deleted ? row.id : undefined;
  }
}
