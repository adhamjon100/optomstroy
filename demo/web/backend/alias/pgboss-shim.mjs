// Шим `pg-boss` (WP-B2; plan §3.3, §3.4 правила 1 и 3): тот же pg-boss 12.38, но все экземпляры (API, pos-worker,
// SMS) работают на общем PGlite через встроенный адаптер `fromPglite` (backend: 'pglite') под замком сессии pg-shim.
//
// - Обработчик задачи (`work(name, …, handler)`) выполняется как «единица работы» kind 'job' (work-gate.mjs):
//   задачи не перемежаются с запросами приложения и между собой; запросы приложения идут раньше (приоритет).
//   Выборка задач, продление, завершение и обслуживание pg-boss — вне единиц, под замком сессии.
// - Оператор pg-boss решает pg-shim.bossStatement: блоки BEGIN…COMMIT не подсаживаются никогда, внутренние
//   операторы — только в области транзакции держателя, вставка задачи (send без { db: tx }) — и по правилам
//   unit/idle белого списка. Подсаженный оператор идёт под SAVEPOINT мимо адаптера: адаптер при ошибке шлёт
//   ROLLBACK всей сессии и откатил бы чужую транзакцию.
import * as real from 'nm:pg-boss/dist/index.js';
import { bossSessionLocked, bossStatement } from './pg-shim.mjs';
import { run as runUnit } from './work-gate.mjs';

export * from 'nm:pg-boss/dist/index.js';

export const bossStats = { statements: 0, jobUnits: 0, jobUnitErrors: 0, byQueue: {} };
let shared = null;

export function attachPgliteToBoss(db) {
  const inner = real.fromPglite(db);
  const locked = {
    executeSql(text, values) {
      bossStats.statements++;
      return bossStatement(text, values, () => inner.executeSql(text, values));
    },
    setSessionStatements(s) {
      return bossSessionLocked('pg-boss.session', 'session statements', () => inner.setSessionStatements?.(s));
    },
  };
  // LISTEN/UNLISTEN внутри чужой транзакции пропали бы при её откате — только под замком, без подсадки.
  if (inner.listen) {
    locked.listen = async (channel, onNotification, onReconnect) => {
      const sub = await bossSessionLocked('pg-boss.listen', `LISTEN ${channel}`, () => inner.listen(channel, onNotification, onReconnect));
      return { close: () => bossSessionLocked('pg-boss.unlisten', `UNLISTEN ${channel}`, () => sub.close()) };
    };
  }
  shared = locked;
}

// Слушатели «после следующей задачи очереди» (fix round 1, WP-T1 дефект 3: догоняние ставит receivables только после
// customers — demo-init.mjs catchUp). Вызываются один раз, когда обработчик задачи очереди завершился (успешно или
// с ошибкой) и его единица работы закончилась — то есть вне единицы, после COMMIT обработчика.
const afterJob = new Map(); // очередь → Set<fn>
/** Один раз вызвать fn({ ok, error? }) после завершения следующей задачи очереди queue. Возвращает отмену. */
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
      // слушатель — побочное действие; ошибка не меняет итог задачи
    }
  }
}

/** Обёртка обработчика задачи: единица работы kind 'job' с именем очереди. */
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
    const opts = typeof value === 'string' ? {} : { ...value };
    delete opts.connectionString;
    delete opts.max;
    delete opts.application_name;
    if (!shared) throw new Error('pgboss-shim: attachPgliteToBoss(db) не вызван до создания PgBoss');
    super({ ...opts, db: shared, backend: 'pglite' });
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
