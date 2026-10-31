// Подмена dist/customers/jobs/customer-onec-results.handler.js (WP-B2, continuations-audit.md): тот же
// CustomerOnecResultsHandler, но reconcile() — сверка результатов создания клиентов в 1С, которую
// customers-jobs.bridge запускает по таймеру раз в 5 минут, — выполняется «единицей работы» kind 'job'
// (alias/work-gate.mjs). Вызов изнутри активной единицы (по асинхронному стеку) идёт на месте, без очереди.
import * as original from '@pos-api-dist/customers/jobs/customer-onec-results.handler.js';
import { runTimerUnit } from './work-gate.mjs';

export const { CustomerOnecResultsHandler } = original;

if (!CustomerOnecResultsHandler.prototype.__posGateWrapped) {
  const reconcile = CustomerOnecResultsHandler.prototype.reconcile;
  CustomerOnecResultsHandler.prototype.reconcile = function wrappedReconcile(...args) {
    return runTimerUnit('customers.reconcile', () => reconcile.apply(this, args));
  };
  CustomerOnecResultsHandler.prototype.__posGateWrapped = true;
}
