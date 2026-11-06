import { type CanActivate, type ExecutionContext, Injectable } from '@nestjs/common';
import type { RequestWithContext } from '../http/request-context.js';

/**
 * Маршрут намеренно **не** идемпотентен, а тело или ответ несут секрет, который не должен попасть в `idempotency_keys`
 * (ни как сохранённый ответ, ни как `request_hash` — SHA-256 канонического тела, `fingerprint.ts`): guard контроллера
 * выполняется до глобального IdempotencyInterceptor и удаляет заголовок `Idempotency-Key` — ключ игнорируется, итог
 * не сохраняется, повтор выполняется заново. Маршруты:
 * - `POST /admin/users/{id}/emergency-login-code` (08 §4.18.10): ответ — код входа, повтор обязан выдать новый код;
 * - `POST /kiosk/order-otp` (08 §4.25.1): новый запрос — новый код (`challengeId`), номер покупателя в теле;
 * - `POST /kiosk/exit` (08 §4.25.5 «Идемпотентность — ключ не требуется»; 11 SEC-140 п. 6): аварийный код из 8 цифр
 *   в теле не пишется в хранилище идемпотентности — его хэш при 10^8 вариантах обращается за секунды.
 */
@Injectable()
export class IgnoreIdempotencyKeyGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    if (context.getType() !== 'http') return true;
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    delete req.headers['idempotency-key'];
    return true;
  }
}
