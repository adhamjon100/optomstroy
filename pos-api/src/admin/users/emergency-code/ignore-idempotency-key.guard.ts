import { type CanActivate, type ExecutionContext, Injectable } from '@nestjs/common';
import type { RequestWithContext } from '../../../common/http/request-context.js';

/**
 * Маршрут намеренно **не** идемпотентен (08 §4.18.10): ответ содержит секрет и не должен попасть в
 * `idempotency_keys`, а повтор обязан выдать новый код. Guard контроллера выполняется до глобального
 * IdempotencyInterceptor и удаляет заголовок `Idempotency-Key` — ключ игнорируется, итог не сохраняется.
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
