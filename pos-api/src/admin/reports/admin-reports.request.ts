import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';

/** Период отчётов — не более 366 дней (08 §4.18.8, ядро §19.4). */
export const REPORT_MAX_RANGE_MS = 366 * 86_400_000;
/**
 * Период по умолчанию, если `from`/`to` не заданы: последние 30 суток до `to` (значения по умолчанию журналов —
 * Q-215, решение заказчика не принято; GQ-ADM-05).
 */
export const REPORT_DEFAULT_RANGE_MS = 30 * 86_400_000;

export type SalesGroupBy = 'day' | 'seller' | 'paymentMethod';
export type QrStatusFilter = 'all' | 'unmatched' | 'manual';

export interface ReportPeriod {
  readonly from: Date;
  readonly to: Date;
}

function one(v: unknown): string | undefined {
  if (Array.isArray(v)) return one(v[0]);
  return typeof v === 'string' && v !== '' ? v : undefined;
}

function fail(errors: ProblemFieldError[], status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status,
    detail: 'Параметры отчёта не прошли проверку.',
    errors,
  });
}

/**
 * `format` (08 §4.18.8): `json` (по умолчанию) | `csv`. Экспорт CSV — R2 (`reports.export`, Q-217, ядро §19.2): в R1
 * код никому не выдан → `403 FORBIDDEN` (API-119). Иное значение — `400 VALIDATION_FAILED` rule `enum`.
 */
export function assertJsonFormat(q: Record<string, unknown>): void {
  const f = one(q.format);
  if (f === undefined || f === 'json') return;
  if (f === 'csv') {
    throw new ProblemException('FORBIDDEN', {
      detail: 'Экспорт отчётов в CSV недоступен в текущей версии.',
      reason: 'export_not_available',
    });
  }
  throw fail([{ field: 'format', rule: 'enum', message: 'Допустимо: json.' }]);
}

/**
 * Период `from`/`to` (UTC, ISO-8601; необязательны): формат — 400 `date_time`; `from > to` или > 366 дней — 422
 * `date_range` (контракт `admin_reports_*`); по умолчанию `to = now`, `from = to − 30 суток`.
 */
export function parseReportPeriod(q: Record<string, unknown>, now: Date): ReportPeriod {
  const errors: ProblemFieldError[] = [];
  const date = (field: 'from' | 'to'): Date | undefined => {
    const s = one(q[field]);
    if (s === undefined) return undefined;
    const d = new Date(s);
    if (Number.isNaN(d.getTime()) || !/^\d{4}-\d{2}-\d{2}/.test(s)) {
      errors.push({ field, rule: 'date_time', message: 'Ожидается дата-время ISO-8601.' });
      return undefined;
    }
    return d;
  };
  const fromRaw = date('from');
  const toRaw = date('to');
  if (errors.length > 0) throw fail(errors);
  const to = toRaw ?? (fromRaw && fromRaw > now ? new Date(fromRaw.getTime() + REPORT_DEFAULT_RANGE_MS) : now);
  const from = fromRaw ?? new Date(to.getTime() - REPORT_DEFAULT_RANGE_MS);
  if (from > to || to.getTime() - from.getTime() > REPORT_MAX_RANGE_MS) {
    throw fail([{ field: 'from', rule: 'date_range', message: 'Период: from ≤ to, не более 366 дней.' }], 422);
  }
  return { from, to };
}

/** `groupBy` ∈ day | seller | paymentMethod (минимум R1, API-119); иное (`week`, `month`, `warehouse` — R2) → 400. */
export function parseGroupBy(q: Record<string, unknown>): SalesGroupBy {
  const g = one(q.groupBy) ?? 'day';
  if (g === 'day' || g === 'seller' || g === 'paymentMethod') return g;
  throw fail([{ field: 'groupBy', rule: 'groupBy', message: 'Допустимо: day, seller, paymentMethod.' }]);
}

/** `status` отчёта QR-сверки ∈ all | unmatched | manual (08 §4.18.8). */
export function parseQrStatus(q: Record<string, unknown>): QrStatusFilter {
  const s = one(q.status) ?? 'all';
  if (s === 'all' || s === 'unmatched' || s === 'manual') return s;
  throw fail([{ field: 'status', rule: 'enum', message: 'Допустимо: all, unmatched, manual.' }]);
}

/** `asOfOnly` отчёта долгов — boolean. */
export function parseAsOfOnly(q: Record<string, unknown>): boolean {
  const v = one(q.asOfOnly);
  if (v === undefined || v === 'false') return false;
  if (v === 'true') return true;
  throw fail([{ field: 'asOfOnly', rule: 'type', message: 'Ожидается true или false.' }]);
}
