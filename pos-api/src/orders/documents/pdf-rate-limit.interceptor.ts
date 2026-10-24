import { type CallHandler, type ExecutionContext, Inject, Injectable, type NestInterceptor } from '@nestjs/common';
import type { Observable } from 'rxjs';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { MemoryWindowCounter } from '../../common/rate-limit/http-rate-limit.js';

/**
 * RL-PDF (08 §2.9): `GET /orders/{id}/documents/*.pdf` — 20 запросов в минуту на `userId`, хранилище `memory`.
 * Группа не входит в общий `HttpRateLimitInterceptor` (RL-READ/SEARCH/CART), поэтому подключается к контроллеру
 * документов; превышение → `429 RATE_LIMITED` с `Retry-After`.
 */
export const RL_PDF_PER_MINUTE = 20;
export const RL_PDF_LIMIT = 'orders.documents.rl-pdf-limit' as const;

@Injectable()
export class PdfRateLimitInterceptor implements NestInterceptor {
  private readonly counter = new MemoryWindowCounter();

  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(RL_PDF_LIMIT) private readonly limit: number,
  ) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    const p = req.principal;
    if (!isAuthenticatedPrincipal(p)) return next.handle();
    const r = this.counter.consume(`RL-PDF:${p.userId}`, this.limit, this.clock.now().getTime());
    if (!r.allowed) {
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Слишком много запросов документов. Повторите позже.',
        retryAfter: r.retryAfterSec,
        headers: { 'X-RateLimit-Limit': String(this.limit), 'X-RateLimit-Remaining': '0' },
      });
    }
    return next.handle();
  }
}
