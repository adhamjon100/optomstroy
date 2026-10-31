// WP-B2: «единица работы» (alias/work-gate.mjs, plan §3.4 правило 1). Порядок и приоритеты, старение, окно
// затихания пула, отмена ещё не начатых и начатых единиц, отпускание слота на время ожидания (long-poll) с
// возвратом первым, вложенный вызов, сторож очереди и удержания, принудительное освобождение.
//   node --test "demo/web/backend/test/*.test.mjs"
import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, test } from 'node:test';
import * as gate from '../alias/work-gate.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DEFAULTS = { ...gate.gateConfig };
let activity;

beforeEach(() => {
  gate.configureGate({ ...DEFAULTS, quietMs: 5, quietMaxMs: 60, quietPollMs: 2 });
  activity = { busy: false, lastActivityAt: -Infinity };
  gate.setActivityProbe(() => activity);
  gate.resetGateStats();
  globalThis.__posDemoLog = () => {};
});
afterEach(async () => {
  // слот должен быть свободен после каждого теста
  for (let i = 0; i < 100 && (gate.activeUnit() || gate.gateSnapshot().queued.length); i++) await sleep(5);
  assert.equal(gate.activeUnit(), null, 'слот свободен');
});

describe('work-gate', () => {
  test('единицы выполняются по одной; приоритет app раньше job, внутри класса — FIFO', async () => {
    const order = [];
    let inside = 0;
    let maxInside = 0;
    const unit = (kind, name, ms) =>
      gate.run({ kind, name }, async () => {
        inside++;
        maxInside = Math.max(maxInside, inside);
        order.push(name);
        await sleep(ms);
        inside--;
      });
    const first = unit('job', 'j0', 30); // занимает слот
    await sleep(1);
    const ps = [unit('job', 'j1', 1), unit('seed', 's1', 1), unit('http', 'h1', 1), unit('panel', 'p1', 1), unit('http', 'h2', 1)];
    await Promise.all([first, ...ps]);
    assert.equal(maxInside, 1, 'одновременно выполнялась одна единица');
    assert.deepEqual(order, ['j0', 'h1', 'h2', 'p1', 'j1', 's1']);
  });

  test('старение: задача, ждущая дольше agingMs, идёт раньше нового запроса', async () => {
    gate.configureGate({ agingMs: 20 });
    const order = [];
    const hold = gate.run({ kind: 'http', name: 'hold' }, () => sleep(70));
    await sleep(1);
    const job = gate.run({ kind: 'job', name: 'job' }, () => order.push('job'));
    await sleep(55); // задача ждёт > 2 × agingMs → её класс поднялся до app и выше
    const app = gate.run({ kind: 'http', name: 'app' }, () => order.push('app'));
    await Promise.all([hold, job, app]);
    assert.deepEqual(order, ['job', 'app']);
  });

  test('окно затихания: следующая единица ждёт, пока пул занят, но не дольше quietMaxMs', async () => {
    const t = [];
    activity = { busy: true, lastActivityAt: performance.now() };
    const a = gate.run({ kind: 'http', name: 'a' }, () => t.push(['a', performance.now()]));
    const b = gate.run({ kind: 'http', name: 'b' }, () => t.push(['b', performance.now()]));
    setTimeout(() => (activity = { busy: false, lastActivityAt: performance.now() }), 20);
    await Promise.all([a, b]);
    const gap = t[1][1] - t[0][1];
    assert.ok(gap >= 20 && gap < 60, `b начата через ${gap.toFixed(1)} мс (пул затих через 20 мс)`);
    activity = { busy: true, lastActivityAt: performance.now() };
    const t0 = performance.now();
    await gate.run({ kind: 'http', name: 'c' }, () => undefined);
    const ms = performance.now() - t0;
    activity = { busy: false, lastActivityAt: -Infinity };
    assert.ok(ms >= 55 && ms < 200, `затихание ограничено quietMaxMs: ${ms.toFixed(1)} мс`);
    assert.ok(gate.gateStats.quietTimeouts >= 1);
  });

  test('отмена ещё не начатой единицы: снимается из очереди, функция не вызывается', async () => {
    const ran = [];
    const hold = gate.run({ kind: 'http', name: 'hold' }, () => sleep(30));
    const ps = ['q1', 'q2', 'q3'].map((k) => gate.run({ kind: 'http', name: k, key: k }, () => ran.push(k)));
    assert.equal(gate.cancel('q1'), 'queued');
    assert.equal(gate.cancel('q2'), 'queued');
    assert.equal(gate.cancel('nope'), 'unknown');
    const res = await Promise.allSettled(ps);
    await hold;
    assert.equal(res[0].status, 'rejected');
    assert.equal(res[0].reason.code, 'ERR_DEMO_CANCELLED');
    assert.equal(res[1].reason.code, 'ERR_DEMO_CANCELLED');
    assert.equal(res[2].status, 'fulfilled');
    assert.deepEqual(ran, ['q3']);
    assert.equal(gate.gateStats.cancelledQueued, 2);
  });

  test('отмена начатой единицы: сигнал и onCancel; не завершилась за cancelGraceMs — слот освобождается', async () => {
    gate.configureGate({ cancelGraceMs: 30 });
    let aborted = false;
    let hooked = false;
    let release;
    const slow = gate.run({ kind: 'http', name: 'slow', key: 'slow' }, (u) => {
      u.signal.addEventListener('abort', () => (aborted = true));
      u.onCancel(() => (hooked = true));
      return new Promise((r) => (release = r)); // «зависший» запрос
    });
    await sleep(5);
    let nextAt = 0;
    const next = gate.run({ kind: 'http', name: 'next' }, () => (nextAt = performance.now()));
    const tc = performance.now();
    assert.equal(gate.cancel('slow'), 'running');
    await next;
    assert.ok(aborted && hooked, 'сигнал отмены и обработчик');
    const waited = nextAt - tc;
    assert.ok(waited >= 25 && waited < 150, `следующая начата через ${waited.toFixed(1)} мс после отмены`);
    assert.equal(gate.gateStats.cancelDetached, 1);
    release();
    await slow;
  });

  test('releaseWhile: на время ожидания слот свободен, затем единица возвращается раньше очереди', async () => {
    const order = [];
    let lp;
    const longPoll = gate.run({ kind: 'http', name: 'lp' }, async (u) => {
      lp = u;
      order.push('lp:start');
      await gate.releaseWhile(u, async () => {
        await sleep(30); // ожидание long-poll: другие единицы выполняются
        order.push('lp:wake');
      });
      order.push('lp:resume');
    });
    await sleep(5);
    assert.equal(gate.gateSnapshot().released.length, 1);
    const other = gate.run({ kind: 'http', name: 'other' }, () => order.push('other'));
    await other;
    // пока lp ждёт, слот занимает hold (дольше ожидания lp), за ним в очереди — later; когда hold закончится, в очереди
    // будут и продолжение lp, и later — продолжение должно пройти первым
    const hold = gate.run({ kind: 'job', name: 'hold' }, () => sleep(60));
    await sleep(2);
    const later = gate.run({ kind: 'http', name: 'later' }, () => order.push('later'));
    await Promise.all([longPoll, hold, later]);
    assert.deepEqual(order, ['lp:start', 'other', 'lp:wake', 'lp:resume', 'later']);
    assert.ok(lp.holdMs < 30, `ожидание не считается удержанием: ${lp.holdMs.toFixed(1)} мс`);
    assert.equal(gate.gateStats.releases, 1);
    assert.equal(gate.gateStats.resumes, 1);
  });

  test('вложенный вызов изнутри активной единицы (parent) выполняется на месте, без взаимоблокировки', async () => {
    const r = await gate.run({ kind: 'panel', name: 'outer' }, (u) => gate.run({ kind: 'job', name: 'inner', parent: u.id }, () => 42));
    assert.equal(r, 42);
    assert.equal(gate.gateStats.inline, 1);
  });

  test('сторож: ожидание слота и удержание дольше watchdogMs считаются; overrunMs освобождает слот', async () => {
    gate.configureGate({ watchdogMs: 20, overrunMs: 60 });
    const logs = [];
    globalThis.__posDemoLog = (lv, m) => logs.push(`${lv} ${m}`);
    let release;
    const t0 = performance.now(); // отсчёт overrunMs — от выдачи слота «зависшей» единице
    const stuck = gate.run({ kind: 'job', name: 'stuck' }, () => new Promise((r) => (release = r)));
    await sleep(1);
    let ranAt = 0;
    const waiter = gate.run({ kind: 'http', name: 'waiter' }, () => (ranAt = performance.now()));
    await waiter;
    assert.ok(ranAt - t0 >= 55, `ожидающий получил слот после overrun: ${(ranAt - t0).toFixed(1)} мс`);
    assert.equal(gate.gateStats.holdsOver3s, 1);
    assert.equal(gate.gateStats.queueWaitsOver3s, 1);
    assert.equal(gate.gateStats.overruns, 1);
    assert.ok(logs.some((l) => l.startsWith('error') && l.includes('держит слот')));
    release();
    await stuck;
  });

  test('сторож очереди: задача pg-boss ждёт дольше запроса приложения без ERROR (jobQueueWatchdogMs)', async () => {
    gate.configureGate({ watchdogMs: 20, jobQueueWatchdogMs: 500 });
    const hold = gate.run({ kind: 'http', name: 'hold' }, () => sleep(60));
    await sleep(1);
    const job = gate.run({ kind: 'job', name: 'job' }, () => undefined); // ждёт ~60 мс: больше watchdogMs, меньше jobQueueWatchdogMs
    await Promise.all([hold, job]);
    await sleep(25); // время на срабатывание таймера сторожа, будь он неверным
    assert.equal(gate.gateStats.queueWaitsOver3s, 0);
    assert.ok(gate.gateStats.maxQueueWaitByKind.job >= 30, `задача ждала ${gate.gateStats.maxQueueWaitByKind.job} мс`); // зерно таймеров Windows до ~15 мс
  });

  test('единица по стеку: имя рамки __posUnit_<id> видно в асинхронном стеке', async () => {
    let id = null;
    let names = null;
    await gate.run({ kind: 'job', name: 'stack' }, async (u) => {
      id = u.id;
      await null;
      const prev = Error.prepareStackTrace;
      Error.prepareStackTrace = (_e, s) => s;
      const o = {};
      Error.captureStackTrace(o);
      const sites = o.stack;
      Error.prepareStackTrace = prev;
      names = sites.map((c) => ({ name: c.getFunctionName() }));
    });
    assert.equal(gate.unitIdFromSites(names), id);
    assert.equal(gate.unitIdFromSites([{ name: 'x' }]), null);
  });
});
