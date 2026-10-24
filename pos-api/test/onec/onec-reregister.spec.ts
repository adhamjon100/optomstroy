import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { type ReregisterJournalEntry, runReregister } from '../../scripts/onec_reregister.js';

/**
 * CLI `npm run onec:reregister` (разбор расхождений п. 31; 05 §6.2 п. 4 и уточнение п. 3; ТЗ для 1С 5.2 п. 7, 6.4;
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
