import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  type AuditChainReport,
  formatAuditChainReport,
  runVerifyAuditChainCli,
  verifyAuditChain,
} from './audit-chain.verifier.js';

/**
 * Проверка цепочки аудита (RM-G-006 п. 1–2; 13 RM-G-009 п. 3 — «аудит — 100 % веток»): разбор ответа SQL
 * `audit_verify_chain` и сверка якорей (`verifyAuditChain` на фейке запросов), текст отчёта и CLI
 * `scripts/verify_audit_chain.ts` (pg.Client подменён). Поведение на настоящей БД — test/admin/admin-audit и
 * сквозные test/e2e/cashier.
 */
interface Anchor {
  anchor_date: string;
  last_chain_seq: string;
  ok: boolean;
  missing: boolean;
}

interface FakeDb {
  bounds?: { n: string; lo: string | null; hi: string | null };
  verify?: { ok: boolean; broken: string | null; gaps: number };
  anchors?: Anchor[];
}

function fakeDb(d: FakeDb) {
  return {
    query: (text: string) => {
      if (text.includes('count(*)')) return Promise.resolve({ rows: d.bounds ? [d.bounds] : [] });
      if (text.includes('audit_verify_chain')) return Promise.resolve({ rows: d.verify ? [d.verify] : [] });
      return Promise.resolve({ rows: d.anchors ?? [] });
    },
  } as never;
}

const anchor = (date: string, seq: string, ok = true, missing = false): Anchor => ({
  anchor_date: date,
  last_chain_seq: seq,
  ok,
  missing,
});

interface PgMockState {
  db: { bounds?: unknown; verify?: unknown; anchors?: unknown[] };
  connectError: unknown;
  endReject: boolean;
  urls: string[];
}

const pgState = vi.hoisted((): PgMockState => ({ db: {}, connectError: null, endReject: false, urls: [] }));

vi.mock('pg', () => {
  class Client {
    constructor(cfg: { connectionString: string }) {
      pgState.urls.push(cfg.connectionString);
    }
    connect(): Promise<void> {
      // Ветвь CLI «ошибка не Error»: драйвер может отклонить промис произвольным значением.
      // eslint-disable-next-line @typescript-eslint/prefer-promise-reject-errors
      return pgState.connectError === null ? Promise.resolve() : Promise.reject(pgState.connectError);
    }
    query(text: string): Promise<{ rows: unknown[] }> {
      if (text.includes('count(*)')) return Promise.resolve({ rows: pgState.db.bounds ? [pgState.db.bounds] : [] });
      if (text.includes('audit_verify_chain')) {
        return Promise.resolve({ rows: pgState.db.verify ? [pgState.db.verify] : [] });
      }
      return Promise.resolve({ rows: pgState.db.anchors ?? [] });
    }
    end(): Promise<void> {
      return pgState.endReject ? Promise.reject(new Error('end failed')) : Promise.resolve();
    }
  }
  return { default: { Client } };
});

describe('verifyAuditChain', () => {
  it('пустая таблица: ok, строк 0, без якорей; нет строки счётчика — тоже 0', async () => {
    const empty = await verifyAuditChain(fakeDb({ bounds: { n: '0', lo: null, hi: null } }));
    expect(empty).toMatchObject({ ok: true, rows: 0, firstChainSeq: null, lastChainSeq: null, gaps: 0 });
    expect(empty.lastGoodAnchor).toBeNull();
    // Счётчик без границ (не бывает при n > 0, ветвь защитная) — функция цепочки не вызывается.
    const odd = await verifyAuditChain(
      fakeDb({ bounds: { n: '1', lo: null, hi: null }, verify: { ok: false, broken: '1', gaps: 0 } }),
    );
    expect(odd).toMatchObject({ ok: true, rows: 1, brokenAtChainSeq: null });
    const none = await verifyAuditChain(fakeDb({}));
    expect(none).toMatchObject({ ok: true, rows: 0, firstChainSeq: null, brokenAtChainSeq: null, anchorsChecked: 0 });
  });

  it('целая цепочка с пропусками и якорями: последний якорь — целый', async () => {
    const r = await verifyAuditChain(
      fakeDb({
        bounds: { n: '5', lo: '1', hi: '6' },
        verify: { ok: true, broken: null, gaps: 1 },
        anchors: [anchor('2026-10-01', '2'), anchor('2026-10-02', '5')],
      }),
    );
    expect(r).toMatchObject({ ok: true, rows: 5, firstChainSeq: '1', lastChainSeq: '6', gaps: 1, anchorsChecked: 2 });
    expect(r.lastGoodAnchor).toEqual({ anchorDate: '2026-10-02', lastChainSeq: '5' });
    expect(r.anchorFailures).toEqual([]);
  });

  it('функция audit_verify_chain не вернула строку — считается целой (ok, gaps 0)', async () => {
    const r = await verifyAuditChain(fakeDb({ bounds: { n: '2', lo: '1', hi: '2' } }));
    expect(r).toMatchObject({ ok: true, brokenAtChainSeq: null, gaps: 0 });
  });

  it('разрыв и несовпадающие якоря: граница — меньший из (разрыв, первый плохой якорь)', async () => {
    const r = await verifyAuditChain(
      fakeDb({
        bounds: { n: '9', lo: '1', hi: '9' },
        verify: { ok: false, broken: '4', gaps: 0 },
        anchors: [
          anchor('2026-10-01', '2'),
          anchor('2026-10-02', '3', false, false),
          anchor('2026-10-03', '5'),
          anchor('2026-10-04', '6', false, true),
        ],
      }),
    );
    expect(r.ok).toBe(false);
    expect(r.brokenAtChainSeq).toBe('4');
    expect(r.anchorFailures).toEqual([
      { anchorDate: '2026-10-02', lastChainSeq: '3', reason: 'hash_mismatch' },
      { anchorDate: '2026-10-04', lastChainSeq: '6', reason: 'row_missing' },
    ]);
    expect(r.lastGoodAnchor).toEqual({ anchorDate: '2026-10-01', lastChainSeq: '2' });
  });

  it('разрыв раньше плохого якоря; только плохой якорь без разрыва; разрыв без якорей', async () => {
    const early = await verifyAuditChain(
      fakeDb({
        bounds: { n: '9', lo: '1', hi: '9' },
        verify: { ok: false, broken: '3', gaps: 0 },
        anchors: [anchor('2026-10-01', '2'), anchor('2026-10-02', '7', false, false)],
      }),
    );
    expect(early.lastGoodAnchor).toEqual({ anchorDate: '2026-10-01', lastChainSeq: '2' });
    const anchorOnly = await verifyAuditChain(
      fakeDb({
        bounds: { n: '9', lo: '1', hi: '9' },
        verify: { ok: true, broken: null, gaps: 0 },
        anchors: [anchor('2026-10-01', '2', false, true), anchor('2026-10-02', '7')],
      }),
    );
    expect(anchorOnly).toMatchObject({ ok: false, brokenAtChainSeq: null, lastGoodAnchor: null });
    const noAnchors = await verifyAuditChain(
      fakeDb({ bounds: { n: '3', lo: '1', hi: '3' }, verify: { ok: false, broken: '1', gaps: 2 } }),
    );
    expect(noAnchors).toMatchObject({ ok: false, brokenAtChainSeq: '1', gaps: 2, lastGoodAnchor: null });
  });
});

describe('formatAuditChainReport', () => {
  const base: AuditChainReport = {
    ok: true,
    rows: 3,
    firstChainSeq: '1',
    lastChainSeq: '3',
    brokenAtChainSeq: null,
    gaps: 0,
    lastGoodAnchor: { anchorDate: '2026-10-01', lastChainSeq: '2' },
    anchorFailures: [],
    anchorsChecked: 1,
  };

  it('цела: с последним якорем и без него (пустая таблица — «—»)', () => {
    expect(formatAuditChainReport(base)).toEqual([
      'audit_logs: строк 3, chain_seq 1…3, пропусков 0; якорей проверено 1',
      'ЦЕПОЧКА ЦЕЛА; последний якорь 2026-10-01 (chain_seq 2)',
    ]);
    const empty = formatAuditChainReport({
      ...base,
      rows: 0,
      firstChainSeq: null,
      lastChainSeq: null,
      lastGoodAnchor: null,
      anchorsChecked: 0,
    });
    expect(empty).toEqual(['audit_logs: строк 0, chain_seq —…—, пропусков 0; якорей проверено 0', 'ЦЕПОЧКА ЦЕЛА']);
  });

  it('разрыв и плохие якоря: последний целый якорь или «под подозрением вся таблица»', () => {
    const broken = formatAuditChainReport({
      ...base,
      ok: false,
      brokenAtChainSeq: '3',
      anchorFailures: [{ anchorDate: '2026-10-02', lastChainSeq: '3', reason: 'hash_mismatch' }],
    });
    expect(broken.slice(1)).toEqual([
      'РАЗРЫВ ЦЕПОЧКИ: chain_seq 3',
      'ЯКОРЬ 2026-10-02 (chain_seq 3) НЕ СХОДИТСЯ: hash_mismatch',
      'последний целый якорь: 2026-10-01 (chain_seq 2); строки после него — под подозрением',
    ]);
    const anchorOnly = formatAuditChainReport({
      ...base,
      ok: false,
      lastGoodAnchor: null,
      anchorFailures: [{ anchorDate: '2026-10-01', lastChainSeq: '2', reason: 'row_missing' }],
    });
    expect(anchorOnly.slice(1)).toEqual([
      'ЯКОРЬ 2026-10-01 (chain_seq 2) НЕ СХОДИТСЯ: row_missing',
      'целых якорей до разрыва нет: под подозрением вся таблица',
    ]);
  });
});

describe('runVerifyAuditChainCli', () => {
  const dir = mkdtempSync(join(tmpdir(), 'verify-audit-chain-'));
  const urlFile = join(dir, 'database_url');
  writeFileSync(urlFile, ' postgres://u@127.0.0.1:1/db \n');
  const io = () => {
    const out: string[] = [];
    const err: string[] = [];
    return { out, err, io: { out: (l: string) => out.push(l), err: (l: string) => err.push(l) } };
  };

  beforeEach(() => {
    pgState.db = {
      bounds: { n: '2', lo: '1', hi: '2' },
      verify: { ok: true, broken: null, gaps: 0 },
      anchors: [anchor('2026-10-01', '2')],
    };
    pgState.connectError = null;
    pgState.endReject = false;
    pgState.urls.length = 0;
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('--help → 0 (вывод по умолчанию — stdout); неизвестный флаг → 2 (по умолчанию — stderr)', async () => {
    const c = io();
    expect(await runVerifyAuditChainCli(['--help'], {}, c.io)).toBe(0);
    expect(c.out[0]).toMatch(/^usage: verify_audit_chain/);
    const write = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const error = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect(await runVerifyAuditChainCli(['-h'], {})).toBe(0);
      expect(write).toHaveBeenCalled();
      expect(await runVerifyAuditChainCli(['--bogus'], {})).toBe(2);
      expect(String(error.mock.calls[0]?.[0])).toMatch(/verify_audit_chain: .*bogus/);
    } finally {
      write.mockRestore();
      error.mockRestore();
    }
  });

  it('нет подключения → 2; DATABASE_URL_FILE не читается → 2', async () => {
    const c = io();
    expect(await runVerifyAuditChainCli([], {}, c.io)).toBe(2);
    expect(c.err[0]).toMatch(/не задано подключение/);
    expect(await runVerifyAuditChainCli([], { DATABASE_URL_FILE: join(dir, 'нет-файла') }, c.io)).toBe(2);
    expect(c.err[1]).toMatch(/DATABASE_URL_FILE/);
  });

  it('цепочка цела: DATABASE_URL_FILE (обрезка пробелов) → текст отчёта, код 0', async () => {
    const c = io();
    expect(await runVerifyAuditChainCli([], { DATABASE_URL_FILE: urlFile }, c.io)).toBe(0);
    expect(pgState.urls).toEqual(['postgres://u@127.0.0.1:1/db']);
    expect(c.out.at(-1)).toMatch(/^ЦЕПОЧКА ЦЕЛА/);
  });

  it('разрыв: DATABASE_URL, --json → JSON-отчёт, код 1; ошибка закрытия соединения не меняет код', async () => {
    pgState.db = { bounds: { n: '2', lo: '1', hi: '2' }, verify: { ok: false, broken: '2', gaps: 0 }, anchors: [] };
    pgState.endReject = true;
    const c = io();
    expect(await runVerifyAuditChainCli(['--json'], { DATABASE_URL: 'postgres://x@127.0.0.1:1/db' }, c.io)).toBe(1);
    expect(JSON.parse(c.out[0] ?? '{}')).toMatchObject({ ok: false, brokenAtChainSeq: '2' });
  });

  it('ошибка БД (Error и не-Error) → 2', async () => {
    const c = io();
    pgState.connectError = new Error('connection refused');
    expect(await runVerifyAuditChainCli([], { DATABASE_URL: 'postgres://x@127.0.0.1:1/db' }, c.io)).toBe(2);
    expect(c.err[0]).toMatch(/ошибка БД: connection refused/);
    pgState.connectError = 'сбой';
    expect(await runVerifyAuditChainCli([], { DATABASE_URL: 'postgres://x@127.0.0.1:1/db' }, c.io)).toBe(2);
    expect(c.err[1]).toMatch(/ошибка БД: сбой/);
  });
});
