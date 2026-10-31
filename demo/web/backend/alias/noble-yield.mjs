// Подмена `./utils.js` только для @noble/hashes/esm/argon2.js (WP-B2, alias-map.mjs IMPORT_ALIASES): тот же модуль
// утилит, но nextTick отдаёт управление циклу событий (макрозадача), а не микрозадаче (`async () => {}` в
// @noble/hashes 1.8.0). Без этого `asyncTick: 10` в alias/argon2.mjs не помогал: проверка PIN (~0,4 с) не
// пропускала в воркер ни одного сообщения (отмена, flush на pagehide) и ни одного таймера (сторож единицы работы,
// опрос pg-boss). Другие единицы работы во время хэширования по-прежнему ждут слот (work-gate.mjs).
//
// Чем отдавать: setImmediate шима (MessageChannel, без зажима 4 мс) — но не реже раза в TIMER_EVERY_MS через
// setTimeout(0): порт MessageChannel, на который пишут во время его же разбора, в Node разбирается одним циклом и
// не пропускает таймеры и сообщения других портов (проверено в worker_threads); браузер и так чередует задачи.
// Каждая уступка отмечает «идёт вычисление» (work-gate markBusy): step-up и вход по PIN хэшируют ВНУТРИ транзакции
// (step-up.service.js: db.transaction → pinVerifier.verify), и pg-shim не должен принимать такого держателя за
// простаивающего (подсадка idle чужого оператора).
import { markBusy } from './work-gate.mjs';

export * from 'nm:@noble/hashes/esm/utils.js';

const TIMER_EVERY_MS = 50;
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
let lastTimerYield = 0;
export const nobleYieldStats = { yields: 0, timerYields: 0 };

export const nextTick = () =>
  new Promise((resolve) => {
    nobleYieldStats.yields++;
    markBusy();
    const t = now();
    if (t - lastTimerYield >= TIMER_EVERY_MS) {
      lastTimerYield = t;
      nobleYieldStats.timerYields++;
      setTimeout(resolve, 0);
    } else setImmediate(resolve);
  });
