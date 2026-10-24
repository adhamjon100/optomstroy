import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import pg from 'pg';

/** Итог проверки хэш-цепочки аудита (07 §9.3; 11 SEC-080, SEC-081; RM-G-006 п. 1–2). */
export interface AuditChainReport {
  readonly ok: boolean;
  /** Число строк `audit_logs` в проверенном отрезке. */
  readonly rows: number;
  readonly firstChainSeq: string | null;
  readonly lastChainSeq: string | null;
  /** Первая строка, у которой `prev_hash`/`row_hash` не сходятся; `null` — цепочка цела. */
  readonly brokenAtChainSeq: string | null;
  /** Пропуски `chain_seq` (откаты транзакций — не ошибка, 07 §9.3). */
  readonly gaps: number;
  /** Последний якорь `audit_anchors`, целиком предшествующий разрыву (или последний якорь при целой цепочке). */
  readonly lastGoodAnchor: { readonly anchorDate: string; readonly lastChainSeq: string } | null;
  /** Якоря, чья строка `last_chain_seq` удалена или изменена (`row_missing` / `hash_mismatch`). */
  readonly anchorFailures: readonly {
    readonly anchorDate: string;
    readonly lastChainSeq: string;
    readonly reason: 'row_missing' | 'hash_mismatch';
  }[];
  readonly anchorsChecked: number;
}

type Queryable = Pick<pg.Pool, 'query'> | Pick<pg.Client, 'query'>;

/**
 * Проверка всей таблицы `audit_logs` (SQL `audit_verify_chain`) и сверка якорей `audit_anchors` (строка
 * `last_chain_seq` существует и её `row_hash` равен якорю). Разрыв сообщается относительно последнего целого якоря:
 * строки после него — под подозрением (11 SEC-081, RM-G-006 п. 2). Только чтение — таблицу не меняет.
 */
export async function verifyAuditChain(db: Queryable): Promise<AuditChainReport> {
  const bounds = (
    await db.query<{ n: string; lo: string | null; hi: string | null }>(
      `SELECT count(*)::text AS n, min(chain_seq)::text AS lo, max(chain_seq)::text AS hi FROM audit_logs`,
    )
  ).rows[0];
  const rows = Number(bounds?.n ?? 0);
  let ok = true;
  let broken: string | null = null;
  let gaps = 0;
  if (rows > 0 && bounds?.lo && bounds.hi) {
    const v = (
      await db.query<{ ok: boolean; broken: string | null; gaps: number }>(
        `SELECT ok, broken_at_chain_seq::text AS broken, gaps FROM audit_verify_chain($1::bigint, $2::bigint)`,
        [bounds.lo, bounds.hi],
      )
    ).rows[0];
    ok = v?.ok ?? true;
    broken = v?.broken ?? null;
    gaps = Number(v?.gaps ?? 0);
  }
  const anchors = (
    await db.query<{ anchor_date: string; last_chain_seq: string; ok: boolean; missing: boolean }>(
      `SELECT to_char(an.anchor_date, 'YYYY-MM-DD') AS anchor_date, an.last_chain_seq::text AS last_chain_seq,
              (a.row_hash IS NOT DISTINCT FROM an.last_row_hash) AS ok, (a.id IS NULL) AS missing
         FROM audit_anchors an LEFT JOIN audit_logs a ON a.chain_seq = an.last_chain_seq
        ORDER BY an.last_chain_seq, an.anchor_date`,
    )
  ).rows;
  const anchorFailures = anchors
    .filter((a) => !a.ok)
    .map((a) => ({
      anchorDate: a.anchor_date,
      lastChainSeq: a.last_chain_seq,
      reason: a.missing ? ('row_missing' as const) : ('hash_mismatch' as const),
    }));
  const firstBadAnchor = anchorFailures[0] ? BigInt(anchorFailures[0].lastChainSeq) : null;
  const limit = [broken !== null ? BigInt(broken) : null, firstBadAnchor]
    .filter((x): x is bigint => x !== null)
    .reduce<bigint | null>((m, x) => (m === null || x < m ? x : m), null);
  const good = anchors.filter((a) => a.ok && (limit === null || BigInt(a.last_chain_seq) < limit));
  const lastGood = good.at(-1);
  return {
    ok: ok && anchorFailures.length === 0,
    rows,
    firstChainSeq: bounds?.lo ?? null,
    lastChainSeq: bounds?.hi ?? null,
    brokenAtChainSeq: broken,
    gaps,
    lastGoodAnchor: lastGood ? { anchorDate: lastGood.anchor_date, lastChainSeq: lastGood.last_chain_seq } : null,
    anchorFailures,
    anchorsChecked: anchors.length,
  };
}

export interface ChainCliIo {
  readonly out: (line: string) => void;
  readonly err: (line: string) => void;
}

const USAGE =
  'usage: verify_audit_chain [--json]\n' +
  '  БД: DATABASE_URL_FILE (файл со строкой подключения) или DATABASE_URL; только чтение audit_logs/audit_anchors';

/** Текст отчёта: разрыв — относительно последнего целого якоря (07 §9.3). */
export function formatAuditChainReport(r: AuditChainReport): string[] {
  const lines = [
    `audit_logs: строк ${r.rows}, chain_seq ${r.firstChainSeq ?? '—'}…${r.lastChainSeq ?? '—'}, пропусков ${r.gaps}; ` +
      `якорей проверено ${r.anchorsChecked}`,
  ];
  if (r.ok) {
    lines.push(
      `ЦЕПОЧКА ЦЕЛА${r.lastGoodAnchor ? `; последний якорь ${r.lastGoodAnchor.anchorDate} (chain_seq ${r.lastGoodAnchor.lastChainSeq})` : ''}`,
    );
    return lines;
  }
  if (r.brokenAtChainSeq !== null) lines.push(`РАЗРЫВ ЦЕПОЧКИ: chain_seq ${r.brokenAtChainSeq}`);
  for (const f of r.anchorFailures) {
    lines.push(`ЯКОРЬ ${f.anchorDate} (chain_seq ${f.lastChainSeq}) НЕ СХОДИТСЯ: ${f.reason}`);
  }
  lines.push(
    r.lastGoodAnchor
      ? `последний целый якорь: ${r.lastGoodAnchor.anchorDate} (chain_seq ${r.lastGoodAnchor.lastChainSeq}); ` +
          `строки после него — под подозрением`
      : 'целых якорей до разрыва нет: под подозрением вся таблица',
  );
  return lines;
}

/**
 * CLI `scripts/verify_audit_chain.ts` (RM-G-006 п. 1–2): код выхода 0 — цепочка и якоря целы; 1 — разрыв или
 * несовпадение якоря; 2 — ошибка аргументов/подключения.
 */
export async function runVerifyAuditChainCli(
  argv: readonly string[],
  env: NodeJS.ProcessEnv,
  io: ChainCliIo = { out: (l) => process.stdout.write(`${l}\n`), err: (l) => console.error(l) },
): Promise<number> {
  let json: boolean;
  try {
    const { values } = parseArgs({
      args: [...argv],
      options: { json: { type: 'boolean' }, help: { type: 'boolean', short: 'h' } },
      strict: true,
    });
    if (values.help) {
      io.out(USAGE);
      return 0;
    }
    json = values.json === true;
  } catch (e) {
    // parseArgs бросает только TypeError (ERR_PARSE_ARGS_*).
    io.err(`verify_audit_chain: ${(e as Error).message}\n${USAGE}`);
    return 2;
  }
  let url: string | undefined;
  try {
    url = env.DATABASE_URL_FILE ? readFileSync(env.DATABASE_URL_FILE, 'utf8').trim() : env.DATABASE_URL;
  } catch {
    io.err('verify_audit_chain: не удалось прочитать DATABASE_URL_FILE');
    return 2;
  }
  if (!url) {
    io.err(`verify_audit_chain: не задано подключение к БД\n${USAGE}`);
    return 2;
  }
  const client = new pg.Client({ connectionString: url, application_name: 'verify-audit-chain' });
  try {
    await client.connect();
    const report = await verifyAuditChain(client);
    if (json) io.out(JSON.stringify(report));
    else for (const l of formatAuditChainReport(report)) io.out(l);
    return report.ok ? 0 : 1;
  } catch (e) {
    io.err(`verify_audit_chain: ошибка БД: ${e instanceof Error ? e.message : String(e)}`);
    return 2;
  } finally {
    await client.end().catch(() => undefined);
  }
}
