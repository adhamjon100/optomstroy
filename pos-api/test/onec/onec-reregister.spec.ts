import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import {
  openFileJournal,
  type ReregisterJournalEntry,
  runReregister,
  runReregisterCli,
} from '../../src/cli/onec_reregister.js';

/**
 * CLI `node dist/cli/onec_reregister.js` / `npm run onec:reregister` (разбор расхождений п. 31; 05 §6.2 п. 4 и уточнение п. 3; ТЗ для 1С 5.2 п. 7, 6.4;
 * 16 §14.1 шаг 8): разовая перерегистрация состава плана обмена администратором с журналом и выводом ошибки.
 * 1С — фейк на фикстурах `contracts/onec/fixtures` (тестовые данные).
 */
function harness(mode: 'extension' | 'odata_only' | 'fixtures', gw: OnecGateway) {
  const journal: ReregisterJournalEntry[] = [];
  const out: string[] = [];
  const err: string[] = [];
  return {
    journal,
    out,
    err,
    run: (argv: string[]) =>
      runReregister(argv, {
        config: { ONEC_MODE: mode },
        gateway: () => gw,
        journal: (e) => journal.push(e),
        out: (l) => out.push(l),
        err: (l) => err.push(l),
        now: () => new Date('2026-10-24T02:00:00+06:00'),
      }),
  };
}

describe('onec:reregister', () => {
  it('без --confirm — только /health и журнал «checked», перерегистрация не вызывается', async () => {
    const gw = new FakeOnecGateway();
    const h = harness('extension', gw);
    expect(await h.run([])).toBe(0);
    expect(gw.calls.map((c) => c.operation)).toEqual(['getHealth']);
    expect(h.journal).toMatchObject([
      { action: 'check', result: 'checked', backlogBefore: 142, lastAckMessageNumber: 5120 },
    ]);
    expect(h.out.join('\n')).toMatch(/--confirm/);
  });

  it('--confirm: POST /changes/reregister → 202, журнал «accepted» с причиной и requestId', async () => {
    const gw = new FakeOnecGateway();
    const h = harness('extension', gw);
    expect(await h.run(['--confirm', '--reason', 'переход в рабочий режим'])).toBe(0);
    expect(gw.calls.map((c) => c.operation)).toEqual(['getHealth', 'reregisterChanges']);
    expect(h.journal).toHaveLength(1);
    expect(h.journal[0]).toMatchObject({
      action: 'reregister',
      result: 'accepted',
      httpStatus: 202,
      reason: 'переход в рабочий режим',
      onecMode: 'extension',
      at: '2026-10-23T20:00:00.000Z',
    });
    expect(h.journal[0]?.requestId).toMatch(/^[0-9a-f-]{36}$/);
    expect(h.out.join('\n')).toMatch(/ПРИНЯТО \(202\)/);
  });

  it('отказ 1С (401) — код 1, ошибка в stderr и журнале «failed» с HTTP-статусом и кодом', async () => {
    const real = new FakeOnecGateway();
    const gw = Object.assign(Object.create(real) as FakeOnecGateway, {
      reregisterChanges: () =>
        Promise.reject(new OnecError('reregisterChanges', 401, 'POS_E_UNAUTHORIZED', 'неверный ключ')),
    });
    const h = harness('extension', gw);
    expect(await h.run(['--confirm'])).toBe(1);
    expect(h.journal).toMatchObject([
      { action: 'reregister', result: 'failed', httpStatus: 401, errorCode: 'POS_E_UNAUTHORIZED' },
    ]);
    expect(h.err.join('\n')).toMatch(/ОШИБКА: reregisterChanges: 401 POS_E_UNAUTHORIZED/);
  });

  it('ONEC_MODE=odata_only — отказ (код 2) без обращения к 1С', async () => {
    const gw = new FakeOnecGateway();
    const h = harness('odata_only', gw);
    expect(await h.run(['--confirm'])).toBe(2);
    expect(gw.calls).toEqual([]);
    expect(h.journal).toMatchObject([{ result: 'refused' }]);
  });
});

/**
 * RV-1: CLI живёт в `src/cli` и собирается в `dist/` (в образе нет `scripts/` и `tsx`); журнал проверяется на запись до
 * обращения к 1С. 1С — `ONEC_MODE=fixtures` (фейк на фикстурах, тестовые данные).
 */
describe('onec:reregister — процесс CLI (src/cli → dist/cli)', () => {
  const API_DIR = fileURLToPath(new URL('../../', import.meta.url));
  const ENV = {
    APP_ENV: 'dev',
    MIN_APP_VERSION: 'android=1.0.0',
    DATABASE_URL: 'postgres://x:y@127.0.0.1:1/none',
    ONEC_MODE: 'fixtures',
  };
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'onec-rereg-'));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  function io() {
    const out: string[] = [];
    const err: string[] = [];
    return { out, err, io: { out: (l: string) => out.push(l), err: (l: string) => err.push(l) } };
  }
  const readJournal = (p: string) =>
    readFileSync(p, 'utf8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l) as ReregisterJournalEntry);

  it('--confirm на фикстурах: код 0, журнал-файл с записью accepted (без секретов)', async () => {
    const path = join(dir, 'j.jsonl');
    const o = io();
    expect(await runReregisterCli(['--confirm', '--reason', 'переход', '--journal', path], ENV, o.io)).toBe(0);
    const entries = readJournal(path);
    expect(entries).toMatchObject([
      { action: 'reregister', result: 'accepted', httpStatus: 202, onecMode: 'fixtures' },
    ]);
    expect(readFileSync(path, 'utf8')).not.toMatch(/postgres:|password|token/i);
    expect(o.out.join('\n')).toMatch(/ПРИНЯТО \(202\)/);
  });

  it('журнал недоступен для записи — код 2 до обращения к 1С, причина в stderr', async () => {
    const path = join(dir, 'нет-каталога', 'j.jsonl');
    const o = io();
    expect(await runReregisterCli(['--confirm', '--journal', path], ENV, o.io)).toBe(2);
    expect(existsSync(path)).toBe(false);
    expect(o.err.join('\n')).toMatch(/ОШИБКА КОНФИГУРАЦИИ: журнал .* недоступен для записи/);
    expect(o.out).toEqual([]);
    expect(() => openFileJournal(path)).toThrow(/недоступен для записи/);
  });

  it('конфигурация не загружается — код 2, журнал не создаётся', async () => {
    const path = join(dir, 'j.jsonl');
    const o = io();
    expect(await runReregisterCli(['--journal', path], { ONEC_MODE: 'extension' }, o.io)).toBe(2);
    expect(existsSync(path)).toBe(false);
    expect(o.err.join('\n')).toMatch(/ОШИБКА КОНФИГУРАЦИИ/);
  });

  it('запуск файлом (как `node dist/cli/onec_reregister.js`): код выхода процесса и журнал', () => {
    const path = join(dir, 'j.jsonl');
    const r = spawnSync(
      process.execPath,
      ['--import', 'tsx', join(API_DIR, 'src', 'cli', 'onec_reregister.ts'), '--journal', path],
      { cwd: API_DIR, env: { ...process.env, ...ENV }, encoding: 'utf8', timeout: 60_000 },
    );
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toMatch(/проверка выполнена/);
    expect(readJournal(path)).toMatchObject([{ action: 'check', result: 'checked' }]);
  });

  it('tsconfig.build включает src/cli (CLI попадает в dist/ образа), а build проверяет точку входа', () => {
    const build = JSON.parse(readFileSync(join(API_DIR, 'tsconfig.build.json'), 'utf8')) as { include: string[] };
    expect(build.include).toContain('src/**/*.ts');
    const pkg = JSON.parse(readFileSync(join(API_DIR, 'package.json'), 'utf8')) as {
      scripts: Record<string, string>;
    };
    expect(pkg.scripts['onec:reregister']).toBe('node dist/cli/onec_reregister.js');
    expect(pkg.scripts.build).toMatch(/check-dist-entrypoints\.mjs/);
    expect(readFileSync(join(API_DIR, 'scripts', 'check-dist-entrypoints.mjs'), 'utf8')).toContain(
      "'cli/onec_reregister.js'",
    );
  });
});
