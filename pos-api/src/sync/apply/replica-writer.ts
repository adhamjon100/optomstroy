import type pg from 'pg';
import type { SyncEntity } from '../../common/enums.js';
import type { ApplyScope, CatalogTable, EntityCounts, ItemError, TableCounts } from './apply.types.js';
import { emptyCounts, TABLE_ENTITY } from './apply.types.js';

/** Колонка пакетной записи: имя и тип для `jsonb_to_recordset`. */
export type Column = readonly [name: string, pgType: string];

/** Строка реплики к записи (upsert). */
export interface ReplicaRow {
  /** Ключ сопоставления: `onec_ref` (Ref_Key) или ключ набора регистра (`barcodes.value`). */
  readonly key: string;
  /** `id` строки: существующий или новый (UUID v7). */
  readonly id: string;
  readonly isNew: boolean;
  readonly hash: string;
  readonly dataVersion: string | null;
  /** Значения колонок (включая стандартный набор реплики, кроме `id`). */
  readonly values: Readonly<Record<string, unknown>>;
  /** Для `sync_errors`. */
  readonly onecRef: string | null;
  readonly onecCode: string | null;
}

export interface ReplicaSpec {
  readonly table: CatalogTable;
  /** Ключ конфликта: частичный UNIQUE по `onec_ref` или UNIQUE по `value`. */
  readonly conflict: 'onec_ref' | 'value';
  /** Колонки, которые пишутся и при вставке, и при обновлении (данные 1С + стандартный набор). */
  readonly columns: readonly Column[];
  /** Колонки только при вставке (POS-поля, `path`, `qty_precision` …): обновление их не трогает (07 DATA-163). */
  readonly insertOnly?: readonly Column[];
}

export interface ExistingRow {
  readonly id: string;
  readonly hash: string;
  readonly deletionMark: boolean;
}

export const BATCH = 1000;
/** Не более стольких отдельных записей `sync_errors` на (сущность, код) за применение; остальное — сводкой. */
export const MAX_ITEM_ERRORS = 200;

let savepointSeq = 0;

/** Существующие строки по ключу (`onec_ref`/`value`). */
export async function existingByKey(
  client: pg.PoolClient,
  table: CatalogTable,
  conflict: 'onec_ref' | 'value',
  keys: readonly string[],
): Promise<Map<string, ExistingRow>> {
  const out = new Map<string, ExistingRow>();
  for (let i = 0; i < keys.length; i += 5000) {
    const chunk = keys.slice(i, i + 5000);
    const r = await client.query<{ id: string; key: string; source_hash: string; deletion_mark: boolean }>(
      `SELECT id, ${conflict}::text AS key, source_hash, deletion_mark FROM ${table}
        WHERE ${conflict} = ANY($1::${conflict === 'onec_ref' ? 'uuid' : 'text'}[])`,
      [chunk],
    );
    for (const row of r.rows) out.set(row.key, { id: row.id, hash: row.source_hash, deletionMark: row.deletion_mark });
  }
  return out;
}

/** `onec_ref` → `id` (включая помеченные на удаление: ссылки на них допустимы). */
export async function idsByRef(
  client: pg.PoolClient,
  table: CatalogTable,
  refs: Iterable<string>,
): Promise<Map<string, string>> {
  const list = [...new Set(refs)];
  const out = new Map<string, string>();
  for (let i = 0; i < list.length; i += 5000) {
    const r = await client.query<{ id: string; ref: string }>(
      `SELECT id, onec_ref::text AS ref FROM ${table} WHERE onec_ref = ANY($1::uuid[])`,
      [list.slice(i, i + 5000)],
    );
    for (const row of r.rows) out.set(row.ref, row.id);
  }
  return out;
}

/** Выполнить в точке сохранения; ошибка откатывает только её (транзакция остаётся рабочей). */
export async function inSavepoint<T>(client: pg.PoolClient, fn: () => Promise<T>): Promise<T> {
  const sp = `sp_apply_${++savepointSeq}`;
  await client.query(`SAVEPOINT ${sp}`);
  try {
    const r = await fn();
    await client.query(`RELEASE SAVEPOINT ${sp}`);
    return r;
  } catch (e) {
    await client.query(`ROLLBACK TO SAVEPOINT ${sp}`);
    await client.query(`RELEASE SAVEPOINT ${sp}`);
    throw e;
  }
}

function recordsetDef(cols: readonly Column[]): string {
  return cols.map(([n, t]) => `${quoteIdent(n)} ${t}`).join(', ');
}

function quoteIdent(n: string): string {
  return /^[a-z_][a-z0-9_]*$/.test(n) && n !== 'trigger' && n !== 'type' && n !== 'value' ? n : `"${n}"`;
}

/**
 * Пакетный upsert строк реплики: `INSERT … SELECT FROM jsonb_to_recordset … ON CONFLICT (<ключ>) DO UPDATE …
 * WHERE source_hash IS DISTINCT FROM EXCLUDED.source_hash` (05 SYNC-002, SYNC-031; ONEC-101 — ключ только
 * `onec_ref`/ключ набора, никогда код/артикул/наименование). Ошибка БД пакета → построчная запись в точках
 * сохранения: сбойная строка — в `failed`, остальные применяются.
 */
export async function upsertReplica(
  client: pg.PoolClient,
  spec: ReplicaSpec,
  rows: readonly ReplicaRow[],
): Promise<{ ok: ReplicaRow[]; failed: { row: ReplicaRow; message: string }[] }> {
  if (rows.length === 0) return { ok: [], failed: [] };
  const all: Column[] = [['id', 'uuid'], ...spec.columns, ...(spec.insertOnly ?? [])];
  const names = all.map(([n]) => quoteIdent(n)).join(', ');
  const target = spec.conflict === 'onec_ref' ? '(onec_ref) WHERE onec_ref IS NOT NULL' : '(value)';
  const updates = spec.columns
    .filter(([n]) => n !== spec.conflict)
    .map(([n]) => `${quoteIdent(n)} = EXCLUDED.${quoteIdent(n)}`)
    .join(', ');
  const sql = `INSERT INTO ${spec.table} AS t (${names})
    SELECT ${names} FROM jsonb_to_recordset($1::jsonb) AS x(${recordsetDef(all)})
    ON CONFLICT ${target} DO UPDATE SET ${updates}
    WHERE t.source_hash IS DISTINCT FROM EXCLUDED.source_hash`;
  const payload = (batch: readonly ReplicaRow[]): string =>
    JSON.stringify(batch.map((r) => ({ id: r.id, ...r.values })));
  const ok: ReplicaRow[] = [];
  const failed: { row: ReplicaRow; message: string }[] = [];
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    try {
      await inSavepoint(client, () => client.query(sql, [payload(batch)]));
      ok.push(...batch);
    } catch {
      for (const row of batch) {
        try {
          await inSavepoint(client, () => client.query(sql, [payload([row])]));
          ok.push(row);
        } catch (e) {
          failed.push({ row, message: dbMessage(e) });
        }
      }
    }
  }
  return { ok, failed };
}

/** Сообщение ошибки БД без значений строки (ПДн в каталоге нет, но тексты держим краткими). */
export function dbMessage(e: unknown): string {
  const err = e as { message?: string; code?: string; constraint?: string };
  const parts = [err.code, err.constraint, err.message?.split('\n')[0]].filter(Boolean);
  return parts.join(' ').slice(0, 300) || 'ошибка БД';
}

/** Учёт «увиденных» версий объектов (`sync_entity_versions`, DATA-153): data_version, content_hash, seen_in_run_id. */
export async function upsertVersions(
  client: pg.PoolClient,
  entity: SyncEntity,
  runId: string,
  rows: readonly {
    key: string;
    onecRef: string | null;
    dataVersion: string | null;
    hash: string;
    localId: string | null;
  }[],
  seenAt: Date,
): Promise<void> {
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH).filter((r) => r.key.length >= 1 && r.key.length <= 150);
    if (batch.length === 0) continue;
    await client.query(
      `INSERT INTO sync_entity_versions AS v (entity, onec_key, onec_ref, data_version, content_hash, local_id,
              seen_in_run_id, last_seen_at, first_seen_at)
       SELECT $2::sync_entity, x.k, x.r, x.dv, decode(x.h, 'hex'), x.l, $3::uuid, $4, $4
         FROM jsonb_to_recordset($1::jsonb) AS x(k text, r uuid, dv text, h text, l uuid)
       ON CONFLICT (entity, onec_key) DO UPDATE SET
              onec_ref = EXCLUDED.onec_ref, data_version = EXCLUDED.data_version,
              content_hash = EXCLUDED.content_hash, local_id = EXCLUDED.local_id,
              seen_in_run_id = EXCLUDED.seen_in_run_id, last_seen_at = EXCLUDED.last_seen_at`,
      [
        JSON.stringify(
          batch.map((r) => ({ k: r.key, r: r.onecRef, dv: r.dataVersion, h: hexHash(r.hash), l: r.localId })),
        ),
        entity,
        runId,
        seenAt.toISOString(),
      ],
    );
  }
}

/** `source_hash` может нести префикс (`deleted:`/`unresolved:`) — в `content_hash` пишем SHA-256 hex. */
function hexHash(h: string): string {
  const m = /([0-9a-f]{64})$/.exec(h);
  return m ? m[1] : '00'.repeat(32);
}

// ------------------------------------------------------------------ счётчики и ошибки

export function entityCounts(scope: ApplyScope, entity: SyncEntity): EntityCounts {
  let c = scope.counts.get(entity);
  if (!c) {
    c = { ...emptyCounts(), tables: {} };
    scope.counts.set(entity, c);
  }
  return c;
}

export function tableCounts(scope: ApplyScope, table: CatalogTable): { entity: EntityCounts; table: TableCounts } {
  const e = entityCounts(scope, TABLE_ENTITY[table]);
  let t = e.tables[table];
  if (!t) {
    t = emptyCounts();
    e.tables[table] = t;
  }
  return { entity: e, table: t };
}

export function bump(scope: ApplyScope, table: CatalogTable, field: keyof TableCounts, n = 1): void {
  if (n === 0) return;
  const { entity, table: t } = tableCounts(scope, table);
  t[field] += n;
  entity[field] += n;
}

export function itemError(scope: ApplyScope, table: CatalogTable, err: Omit<ItemError, 'entity'>): void {
  scope.errors.push({ entity: TABLE_ENTITY[table], ...err });
  bump(scope, table, 'errors');
}

/**
 * Записать накопленные ошибки позиций в `sync_errors` (в транзакции применения) и очистить список.
 * Не более `MAX_ITEM_ERRORS` записей на (сущность, код); остаток — одной сводной записью.
 */
export async function flushErrors(scope: ApplyScope): Promise<number> {
  if (scope.errors.length === 0) return 0;
  const groups = new Map<string, ItemError[]>();
  for (const e of scope.errors) {
    const k = `${e.entity}|${e.errorCode}`;
    const g = groups.get(k);
    if (g) g.push(e);
    else groups.set(k, [e]);
  }
  const rows: Record<string, unknown>[] = [];
  for (const g of groups.values()) {
    for (const e of g.slice(0, MAX_ITEM_ERRORS)) rows.push(await errorRow(scope, e));
    if (g.length > MAX_ITEM_ERRORS) {
      const first = g[0];
      rows.push(
        await errorRow(scope, {
          entity: first.entity,
          errorCode: first.errorCode,
          severity: first.severity,
          message: `ещё ${g.length - MAX_ITEM_ERRORS} позиций с той же ошибкой (сводка)`,
        }),
      );
    }
  }
  for (let i = 0; i < rows.length; i += BATCH) {
    await scope.client.query(
      `INSERT INTO sync_errors (sync_run_id, entity, onec_ref, onec_code, local_id, error_code, message, payload, severity)
       SELECT x.run, x.entity, x.onec_ref, x.onec_code, x.local_id, x.error_code, x.message, x.payload, x.severity
         FROM jsonb_to_recordset($1::jsonb) AS x(run uuid, entity sync_entity, onec_ref uuid, onec_code text,
              local_id uuid, error_code text, message text, payload jsonb, severity text)`,
      [JSON.stringify(rows.slice(i, i + BATCH))],
    );
  }
  const n = scope.errors.length;
  scope.errors.length = 0;
  return n;
}

async function errorRow(scope: ApplyScope, e: ItemError): Promise<Record<string, unknown>> {
  return {
    run: await scope.runIdFor(e.entity),
    entity: e.entity,
    onec_ref: e.onecRef ?? null,
    onec_code: e.onecCode ? e.onecCode.slice(0, 150) : null,
    local_id: e.localId ?? null,
    error_code: e.errorCode,
    message: e.message.slice(0, 2000),
    payload: e.payload ?? null,
    severity: e.severity,
  };
}
