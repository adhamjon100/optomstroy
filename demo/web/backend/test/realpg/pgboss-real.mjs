// Сверка с настоящим PostgreSQL (review fixes, critic [18]): подмена alias/pgboss-shim.mjs. Настоящий pg-boss 12.38
// на своём пуле настоящего сервера (connectionString pos-api), но обработчики задач — те же «единицы работы»
// (alias/work-gate.mjs), что в демо: сравнивается слой базы данных, а не планирование.
import * as real from 'nm:pg-boss/dist/index.js';
import { run as runUnit } from '../../alias/work-gate.mjs';

export * from 'nm:pg-boss/dist/index.js';

export const bossStats = { statements: 0, jobUnits: 0, jobUnitErrors: 0, byQueue: {}, real: true };
export function attachPgliteToBoss() {}

const afterJob = new Map();
export function afterNextJob(queue, fn) {
  let set = afterJob.get(queue);
  if (!set) afterJob.set(queue, (set = new Set()));
  set.add(fn);
  return () => set.delete(fn);
}
function fireAfterJob(queue, outcome) {
  const set = afterJob.get(queue);
  if (!set || set.size === 0) return;
  afterJob.delete(queue);
  for (const fn of set) {
    try {
      fn(outcome);
    } catch {
      /* слушатель — побочное действие */
    }
  }
}
function asUnit(queue, handler) {
  return function posJobUnit(...args) {
    bossStats.jobUnits++;
    bossStats.byQueue[queue] = (bossStats.byQueue[queue] ?? 0) + 1;
    return runUnit({ kind: 'job', name: queue, label: `job ${queue}` }, () => handler.apply(this, args)).then(
      (r) => {
        fireAfterJob(queue, { ok: true });
        return r;
      },
      (e) => {
        bossStats.jobUnitErrors++;
        fireAfterJob(queue, { ok: false, error: e });
        throw e;
      },
    );
  };
}

export class PgBoss extends real.PgBoss {
  constructor(value) {
    super(typeof value === 'string' ? { connectionString: value } : { ...value });
  }
  work(name, ...args) {
    let i = -1;
    for (let j = args.length - 1; j >= 0; j--)
      if (typeof args[j] === 'function') {
        i = j;
        break;
      }
    if (i >= 0) args[i] = asUnit(String(name), args[i]);
    return super.work(name, ...args);
  }
}
export default PgBoss;
