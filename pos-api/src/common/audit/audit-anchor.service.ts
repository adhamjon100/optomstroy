import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DRIZZLE } from '../db/database.module.js';
import type { DbExecutor } from './db-executor.js';

/** Часовой пояс суток якоря (07 §9.3: job `audit.anchor` в 00:30 Asia/Bishkek). */
export const AUDIT_ANCHOR_TIME_ZONE = 'Asia/Bishkek';
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export interface AuditAnchor {
  readonly anchorDate: string;
  readonly lastChainSeq: number;
  readonly lastRowHash: Buffer;
  readonly rowsCount: number;
  /** Строка экспорта `anchor_date;last_chain_seq;hex(last_row_hash)` (07 §9.3). */
  readonly exportLine: string;
  /** false — якорь за эту дату уже был (повторный запуск job идемпотентен). */
  readonly created: boolean;
  readonly exportPath?: string;
}

export interface ChainVerification {
  readonly ok: boolean;
  readonly brokenAtChainSeq: number | null;
  readonly gaps: number;
}

export interface AnchorVerification {
  readonly anchorDate: string;
  readonly ok: boolean;
  readonly reason?: 'row_missing' | 'hash_mismatch';
}

type AnchorRow = {
  anchor_date: string;
  last_chain_seq: string;
  last_row_hash: Buffer;
  rows_count: string;
};

function toAnchor(r: AnchorRow, created: boolean, exportPath?: string): AuditAnchor {
  const lastChainSeq = Number(r.last_chain_seq);
  return {
    anchorDate: r.anchor_date,
    lastChainSeq,
    lastRowHash: r.last_row_hash,
    rowsCount: Number(r.rows_count),
    exportLine: `${r.anchor_date};${lastChainSeq};${r.last_row_hash.toString('hex')}`,
    created,
    ...(exportPath ? { exportPath } : {}),
  };
}

/**
 * Якоря и проверка хэш-цепочки аудита (07 §9.3; 11 SEC-080, SEC-081; DATA-232, DATA-233). Расписание (job
 * `audit.anchor` / `audit.verify`) — воркер; здесь — операции, которые он вызывает.
 */
@Injectable()
export class AuditAnchorService {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /**
   * Якорь суток `anchorDate` (YYYY-MM-DD, сутки Asia/Bishkek): последняя строка цепочки с `occurred_at` до конца
   * суток (`max(chain_seq)`), число строк за сутки. Пустая таблица → `null`. С `exportDir` — файл
   * `<exportDir>/<YYYY-MM-DD>.txt` с `exportLine` и отметка `exported_at/export_location`.
   */
  async writeDailyAnchor(
    anchorDate: string,
    opts: { readonly exportDir?: string; readonly executor?: DbExecutor } = {},
  ): Promise<AuditAnchor | null> {
    if (!DATE_RE.test(anchorDate)) throw new RangeError('anchorDate: YYYY-MM-DD');
    const ex = opts.executor ?? this.db;
    const ins = await ex.execute<AnchorRow>(sql`
      WITH bounds AS (
        SELECT (${anchorDate}::date)::timestamp AT TIME ZONE ${AUDIT_ANCHOR_TIME_ZONE} AS d0,
               (${anchorDate}::date + 1)::timestamp AT TIME ZONE ${AUDIT_ANCHOR_TIME_ZONE} AS d1
      ), last_row AS (
        SELECT a.chain_seq, a.row_hash FROM audit_logs a, bounds b
         WHERE a.occurred_at < b.d1 ORDER BY a.chain_seq DESC LIMIT 1
      ), cnt AS (
        SELECT count(*) AS n FROM audit_logs a, bounds b WHERE a.occurred_at >= b.d0 AND a.occurred_at < b.d1
      )
      INSERT INTO audit_anchors (anchor_date, last_chain_seq, last_row_hash, rows_count)
      SELECT ${anchorDate}::date, l.chain_seq, l.row_hash, c.n FROM last_row l, cnt c
      ON CONFLICT (anchor_date) DO NOTHING
      RETURNING to_char(anchor_date, 'YYYY-MM-DD') AS anchor_date, last_chain_seq, last_row_hash, rows_count`);
    let row = ins.rows[0];
    const created = row !== undefined;
    if (!row) {
      const existing = await ex.execute<AnchorRow>(sql`
        SELECT to_char(anchor_date, 'YYYY-MM-DD') AS anchor_date, last_chain_seq, last_row_hash, rows_count
          FROM audit_anchors WHERE anchor_date = ${anchorDate}::date`);
      row = existing.rows[0];
      if (!row) return null; // аудит пуст — якорить нечего
    }
    if (!opts.exportDir) return toAnchor(row, created);
    const anchor = toAnchor(row, created);
    await mkdir(opts.exportDir, { recursive: true });
    const path = join(opts.exportDir, `${anchor.anchorDate}.txt`);
    await writeFile(path, `${anchor.exportLine}\n`, { encoding: 'utf8', mode: 0o640 });
    await ex.execute(sql`
      UPDATE audit_anchors SET exported_at = now(), export_location = ${path}, updated_at = now()
       WHERE anchor_date = ${anchorDate}::date`);
    return toAnchor(row, created, path);
  }

  /** `audit_verify_chain(from, to)` (07 §9.3); без границ — вся цепочка. */
  async verifyChain(from?: number, to?: number, executor: DbExecutor = this.db): Promise<ChainVerification> {
    const res = await executor.execute<{ ok: boolean; broken_at_chain_seq: string | null; gaps: number }>(sql`
      SELECT v.ok, v.broken_at_chain_seq, v.gaps FROM audit_verify_chain(
        coalesce(${from ?? null}::bigint, (SELECT coalesce(min(chain_seq), 0) FROM audit_logs)),
        coalesce(${to ?? null}::bigint, (SELECT coalesce(max(chain_seq), 0) FROM audit_logs))) v`);
    const r = res.rows[0];
    return {
      ok: r?.ok ?? true,
      brokenAtChainSeq: r?.broken_at_chain_seq === null || r === undefined ? null : Number(r.broken_at_chain_seq),
      gaps: Number(r?.gaps ?? 0),
    };
  }

  /**
   * Сверка якорей с таблицей: строка `last_chain_seq` существует и её `row_hash` совпадает с якорем. Результат
   * пишется в `audit_anchors.verified_at/verify_result` (`ok` | `row_missing` | `hash_mismatch`).
   */
  async verifyAnchors(executor: DbExecutor = this.db): Promise<AnchorVerification[]> {
    const res = await executor.execute<{ anchor_date: string; ok: boolean; missing: boolean }>(sql`
      SELECT to_char(an.anchor_date, 'YYYY-MM-DD') AS anchor_date,
             (a.row_hash IS NOT DISTINCT FROM an.last_row_hash) AS ok, (a.id IS NULL) AS missing
        FROM audit_anchors an LEFT JOIN audit_logs a ON a.chain_seq = an.last_chain_seq
       ORDER BY an.anchor_date`);
    const out: AnchorVerification[] = res.rows.map((r) =>
      r.ok
        ? { anchorDate: r.anchor_date, ok: true }
        : { anchorDate: r.anchor_date, ok: false, reason: r.missing ? 'row_missing' : 'hash_mismatch' },
    );
    for (const v of out) {
      await executor.execute(sql`
        UPDATE audit_anchors SET verified_at = now(), verify_result = ${v.ok ? 'ok' : (v.reason ?? 'broken')},
               updated_at = now()
         WHERE anchor_date = ${v.anchorDate}::date`);
    }
    return out;
  }
}
