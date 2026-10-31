// Подмена dist/integrations/onec/onec-extension.gateway.js (WP-B2, critic «сон шлюза 1С внутри единицы работы»):
// тот же боевой OnecExtensionGateway (контракт /pos/v1/*, коды ошибок, таймауты), но в демо — ОДНА попытка GET
// вместо трёх с паузами 500 мс × 2^n (onec-extension.gateway.ts:55, 111, 437). Причина: повторы идут через
// setTimeout внутри единицы работы, и при «1С недоступна» из панели запрос или задача держали бы слот секундами
// (сторож 3 с, остальные запросы ждут). У имитатора 1С нет временных сбоев, кроме включаемых панелью, поэтому
// повтор лишь откладывает тот же ответ 503. Настройка ONEC_* для повторов в pos-api нет (только конструктор).
//
// Если демо-конфиг всё же задаст несколько попыток (configureOnecGateway), каждая пауза учитывается и пишется в
// журнал (onecGatewayStats.sleeps) — так её видно сторожу и тестам.
import {
  ONEC_HS_DEFAULTS,
  ONEC_INVALID_RESPONSE,
  ONEC_TRANSPORT,
  OnecExtensionGateway as BaseGateway,
} from '@pos-api-dist/integrations/onec/onec-extension.gateway.js';

export { ONEC_HS_DEFAULTS, ONEC_INVALID_RESPONSE, ONEC_TRANSPORT };

export const onecGatewayConfig = { retry: { maxAttempts: 1, baseDelayMs: ONEC_HS_DEFAULTS.retry.baseDelayMs } };
export const onecGatewayStats = { constructed: 0, sleeps: 0, sleepMs: 0 };
const log = (level, msg) => globalThis.__posDemoLog?.(level, msg);

/** Демо-конфиг (WP-B3): { maxAttempts, baseDelayMs } повторов идемпотентных GET. По умолчанию — одна попытка. */
export function configureOnecGateway({ maxAttempts, baseDelayMs } = {}) {
  if (Number.isInteger(maxAttempts) && maxAttempts >= 1) onecGatewayConfig.retry.maxAttempts = maxAttempts;
  if (Number.isFinite(baseDelayMs) && baseDelayMs >= 0) onecGatewayConfig.retry.baseDelayMs = baseDelayMs;
  return { ...onecGatewayConfig.retry };
}

const countedSleep = (ms) => {
  onecGatewayStats.sleeps++;
  onecGatewayStats.sleepMs += ms;
  log('warn', `1С: пауза перед повтором ${ms} мс (демо-конфиг: ${onecGatewayConfig.retry.maxAttempts} попытки)`);
  return new Promise((r) => setTimeout(r, ms));
};

export class OnecExtensionGateway extends BaseGateway {
  constructor(config, transport, sleep) {
    onecGatewayStats.constructed++;
    super({ ...config, retry: config?.retry ?? { ...onecGatewayConfig.retry } }, transport, sleep ?? countedSleep);
  }
}
