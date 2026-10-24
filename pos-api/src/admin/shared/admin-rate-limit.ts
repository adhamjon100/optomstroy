import {
  type CallHandler,
  type ExecutionContext,
  Inject,
  Injectable,
  Module,
  type NestInterceptor,
  Optional,
} from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { from, type Observable, switchMap } from 'rxjs';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RateLimitService } from '../../common/rate-limit/rate-limit.service.js';

/** RL-ADMIN (08 §2.9): 120 запросов в минуту на пользователя. */
export const ADMIN_RATE_LIMIT_PER_MINUTE = 120;
/** Переопределение лимита (тесты; значение по умолчанию — 08 §2.9). */
export const ADMIN_RATE_LIMIT = Symbol('ADMIN_RATE_LIMIT');

/**
 * Маршруты группы RL-ADMIN (08 §2.9; состав приведён к карточкам §4.11.7, §4.17.2, §4.17.3, §4.19.2 и к
 * `x-rate-limit-group: RL-ADMIN` контракта — ревью закрытия F, RC-10): `/admin/*` (любой метод), `POST /sync/*`,
 * `GET /sync/runs`, `GET /sync/runs/{id}`, `GET /sync/runs/{id}/errors`, `GET /sync/outbox`,
 * `POST /orders/{id}/onec-link`, `POST /customers/{id}/links/{linkId}/confirm|reject`, `GET /openapi.json` в
 * production (при `OPENAPI_PUBLIC=true` — тестовый контур — это RL-PUBLIC-IP, §4.19.2). `GET /sync/status` — RL-READ.
 * Путь — без глобального префикса `/api/v1` и query-строки; **без учёта регистра**: маршрутизация Express регистр
 * не различает (`/api/v1/ADMIN/users` попадает в тот же контроллер), значит, и лимит не должен (ревью E-security-1).
 */
export function isAdminRateLimited(
  method: string,
  path: string,
  opts: { readonly openapiPublic?: boolean } = {},
): boolean {
  const p = path
    .replace(/[?#].*$/, '')
    .toLowerCase()
    .replace(/^\/api\/v1(?=\/)/, '')
    .replace(/(?<=.)\/$/, '');
  if (/^\/admin(\/|$)/.test(p)) return true;
  const m = method.toUpperCase();
  if (m === 'GET') {
    if (p === '/openapi.json') return opts.openapiPublic !== true;
    return /^\/sync\/runs(\/[^/]+(\/errors)?)?$/.test(p) || p === '/sync/outbox';
  }
  if (m !== 'POST') return false;
  return (
    /^\/sync\//.test(p) ||
    /^\/orders\/[^/]+\/onec-link$/.test(p) ||
    /^\/customers\/[^/]+\/links\/[^/]+\/(confirm|reject)$/.test(p)
  );
}

/**
 * RL-ADMIN — интерцептор приложения (после guard'ов: субъект уже известен). Счётчик — `rate_limit_counters`
 * (`admin_user_1m`, миграция 0003; DQ-01 / adm A-11): общий для реплик и переживает рестарт; 08 §2.9 допускает
 * `memory`, PostgreSQL строже. Анонимный запрос до этого шага не доходит (AuthGuard → 401). Превышение →
 * 429 RATE_LIMITED c `Retry-After` и `X-RateLimit-*` (08 §2.9). Ограничение `POST /sync/runs` «10 / 10 мин на
 * сущность» (singleton pg-boss) — модуль sync, не здесь.
 */
@Injectable()
export class AdminRateLimitInterceptor implements NestInterceptor {
  private readonly limit: number;

  private readonly openapiPublic: boolean;

  constructor(
    private readonly rateLimit: RateLimitService,
    @Optional() @Inject(ADMIN_RATE_LIMIT) limit?: number,
    @Optional() @Inject(APP_CONFIG) config?: Pick<AppConfig, 'OPENAPI_PUBLIC'>,
  ) {
    this.limit = limit ?? ADMIN_RATE_LIMIT_PER_MINUTE;
    // Без конфигурации — как production: `GET /openapi.json` в RL-ADMIN (строже).
    this.openapiPublic = config?.OPENAPI_PUBLIC === true;
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();
    const req = context.switchToHttp().getRequest<RequestWithContext & { path?: string }>();
    const principal = req.principal;
    const path = req.originalUrl ?? req.url ?? req.path ?? '';
    if (
      !isAuthenticatedPrincipal(principal) ||
      !isAdminRateLimited(req.method ?? 'GET', path, { openapiPublic: this.openapiPublic })
    ) {
      return next.handle();
    }
    return from(this.check(principal.userId)).pipe(switchMap(() => next.handle()));
  }

  private async check(userId: string): Promise<void> {
    const r = await this.rateLimit.consume([{ scope: 'admin_user_1m', subject: userId, limit: this.limit }]);
    if (r.allowed) return;
    throw new ProblemException('RATE_LIMITED', {
      detail: 'Слишком много запросов. Повторите позже.',
      retryAfter: Math.max(1, r.retryAfterSec),
      headers: { 'X-RateLimit-Limit': String(this.limit), 'X-RateLimit-Remaining': '0' },
    });
  }
}

/**
 * Подключение RL-ADMIN ко всему приложению (APP_INTERCEPTOR). Импортируется `AdminModule`; требует глобальных
 * `RateLimitModule` (RateLimitService) и AuthGuard (субъект запроса).
 */
@Module({
  providers: [{ provide: APP_INTERCEPTOR, useClass: AdminRateLimitInterceptor }],
})
export class AdminRateLimitModule {}
