// Подмена dist/payments/long-poll/payment-status-waiter.js (WP-B2, plan §3.3, §3.4 правило 1): тот же класс
// PaymentStatusWaiter (DI Nest, слоты, LISTEN payments_status, тики по Clock — без изменений), но waitForChange на
// время ожидания отпускает «единицу работы» запроса `GET /payments/{id}?wait=N`: пока long-poll ждёт, выполняются
// другие запросы приложения и задачи pg-boss (в том числе опрос QR, который и меняет статус). Перечитывание статуса
// (readStatus) — отдельная короткая единица kind 'poll'. После ожидания единица запроса снова занимает слот
// (приоритет resume) и дописывает ответ.
//
// Единица запроса находится по метке моста (`GET /api/v1/payments/<id>?wait=…`) среди АКТИВНОЙ единицы: у
// http-запросов асинхронный стек обрывается в express/RxJS, поэтому стек тут не помогает. Если активная единица
// не та (запрос отсоединён после отмены, вызов не из моста) — ожидание идёт как в оригинале, без отпускания.
import {
  MAX_WAIT_SECONDS,
  MAX_WAITS_PER_PROCESS,
  MAX_WAITS_PER_USER,
  PAYMENTS_STATUS_CHANNEL,
  PaymentStatusWaiter,
} from '@pos-api-dist/payments/long-poll/payment-status-waiter.js';
import { activeUnit, releaseWhile, run as runUnit } from './work-gate.mjs';

export { MAX_WAIT_SECONDS, MAX_WAITS_PER_PROCESS, MAX_WAITS_PER_USER, PAYMENTS_STATUS_CHANNEL, PaymentStatusWaiter };

export const waiterStats = { waits: 0, released: 0, notReleased: 0, rereads: 0 };
const log = (level, msg) => globalThis.__posDemoLog?.(level, msg);

const isLongPollOf = (u, paymentId) => !!u && u.kind === 'http' && typeof u.label === 'string' && u.label.includes(`/payments/${paymentId}`) && /[?&]wait=/.test(u.label);

const original = PaymentStatusWaiter.prototype.waitForChange;
if (!PaymentStatusWaiter.prototype.__posGateWrapped) {
  PaymentStatusWaiter.prototype.waitForChange = async function waitForChange(paymentId, current, deadline, signal, readStatus) {
    waiterStats.waits++;
    const u = activeUnit();
    if (!isLongPollOf(u, paymentId)) {
      waiterStats.notReleased++;
      log('warn', `payments.wait: активная единица работы не long-poll платежа ${paymentId} (${u?.label ?? '—'}) — ожидание без отпускания`);
      return original.call(this, paymentId, current, deadline, signal, readStatus);
    }
    waiterStats.released++;
    const reread = () => {
      waiterStats.rereads++;
      return runUnit({ kind: 'poll', name: 'payments.wait.reread', label: `poll payment ${paymentId}` }, () => readStatus());
    };
    return releaseWhile(u, () => original.call(this, paymentId, current, deadline, signal, reread));
  };
  PaymentStatusWaiter.prototype.__posGateWrapped = true;
}
