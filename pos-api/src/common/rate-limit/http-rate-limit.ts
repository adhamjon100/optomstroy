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
import type { Observable } from 'rxjs';
// Путь через `../../common/` — правило no-restricted-imports (eslint.config.mjs) по шаблону `../auth/*`.
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../http/request-context.js';
import { ProblemException } from '../problem-details/problem.exception.js';

/**
 * Группы лимитов частоты 08 §2.9 с хранилищем `memory` (ключ — `userId`), которые не закрыты собственными
 * механизмами модулей: RL-READ (600/мин), RL-SEARCH (120/мин), RL-CART (300/мин), RL-FIN (60/мин — финансовые
 * операции: заказ, отмена, платежи, возвраты, создание клиента; ревью F-security-2). Состав маршрутов — ровно
 * `x-rate-limit-group` контракта `contracts/openapi/pos-api.v1.yaml` (тест сверяет). RL-ADMIN — `AdminRateLimitModule`
 * (PostgreSQL), OTP/PIN/логин — `RateLimitService` модулей auth. Ревью E-security-2.
 */
export type HttpRateLimitGroup = 'RL-READ' | 'RL-SEARCH' | 'RL-CART' | 'RL-FIN';

export const HTTP_RATE_LIMITS_PER_MINUTE: Readonly<Record<HttpRateLimitGroup, number>> = {
  'RL-READ': 600,
  'RL-SEARCH': 120,
  'RL-CART': 300,
  'RL-FIN': 60,
};

/** Переопределение лимитов (тесты); по умолчанию — 08 §2.9. */
export const HTTP_RATE_LIMITS = Symbol('HTTP_RATE_LIMITS');

/** Операции групп (метод + шаблон пути контракта, без `/api/v1`). */
export const HTTP_RATE_LIMIT_ROUTES: Readonly<Record<HttpRateLimitGroup, readonly string[]>> = {
  'RL-READ': [
    'GET /catalog/categories',
    'GET /catalog/price-lists',
    'GET /catalog/products',
    'GET /catalog/products/recent',
    'DELETE /catalog/products/recent',
    'GET /catalog/products/{id}',
    'GET /catalog/products/{id}/variants',
    'GET /catalog/sync/{entity}',
    'GET /catalog/units',
    'GET /catalog/warehouses',
    'GET /customers',
    'GET /customers/{id}',
    'GET /customers/{id}/discounts',
    'GET /customers/{id}/links',
    'GET /customers/{id}/orders',
    'GET /customers/{id}/receivables',
    'GET /discounts/rules',
    'GET /favorites/customers',
    'PUT /favorites/customers/{id}',
    'DELETE /favorites/customers/{id}',
    'GET /favorites/products',
    'PUT /favorites/products/{id}',
    'DELETE /favorites/products/{id}',
    'GET /inventory/balances',
    'GET /me',
    'GET /me/consents',
    'POST /me/consents',
    'PATCH /me/profile',
    'PUT /me/settings',
    'GET /notifications',
    'POST /notifications/read-all',
    'POST /notifications/{id}/read',
    'GET /orders',
    'GET /orders/{id}',
    'GET /orders/{id}/payments',
    'GET /payments/{id}',
    'GET /pos/dashboard',
    'GET /receivables/overdue',
    'GET /registration/customer-match',
    'GET /returns',
    'GET /returns/{id}',
    'GET /settings/public',
    'GET /sync/status',
    'GET /transactions',
    'GET /transactions/{id}',
  ],
  'RL-SEARCH': ['GET /search/barcode/{value}', 'GET /search/customers', 'GET /search/products', 'GET /search/suggest'],
  'RL-CART': [
    'GET /cart',
    'DELETE /cart',
    'PATCH /cart',
    'POST /cart/checkout-preview',
    'POST /cart/customer',
    'DELETE /cart/customer',
    'POST /cart/discount',
    'PUT /cart/items/{variantId}',
    'DELETE /cart/items/{variantId}',
    'POST /cart/park',
    'GET /cart/parked',
    'DELETE /cart/parked/{id}',
    'POST /cart/parked/{id}/resume',
    'POST /inventory/check',
  ],
  'RL-FIN': [
    'POST /customers',
    'POST /orders',
    'POST /orders/{id}/cancel',
    'POST /orders/{id}/payments',
    'POST /payments',
    'POST /payments/{id}/confirm-manual',
    'POST /payments/{id}/void',
    'POST /returns',
    'DELETE /returns/{id}',
    'PATCH /returns/{id}',
    'POST /returns/{id}/accept',
    'POST /returns/{id}/reject',
    'POST /returns/{id}/submit',
  ],
};

interface CompiledRoute {
  readonly group: HttpRateLimitGroup;
  readonly method: string;
  readonly segments: readonly (string | null)[];
}

const COMPILED: readonly CompiledRoute[] = (Object.keys(HTTP_RATE_LIMIT_ROUTES) as HttpRateLimitGroup[]).flatMap(
  (group) =>
    HTTP_RATE_LIMIT_ROUTES[group].map((op) => {
      const [method = '', path = ''] = op.split(' ');
      return {
        group,
        method,
        segments: path
          .split('/')
          .filter(Boolean)
          .map((s) => (s.startsWith('{') ? null : s.toLowerCase())),
      };
    }),
);

/**
 * Группа запроса по методу и пути (без регистра — маршрутизация Express регистр не различает, ревью E-security-1).
 * Литеральный сегмент шаблона важнее параметра (`/catalog/products/recent` раньше `/catalog/products/{id}`).
 */
export function httpRateLimitGroup(method: string, rawPath: string): HttpRateLimitGroup | undefined {
  const m = method.toUpperCase();
  const path = rawPath
    .replace(/[?#].*$/, '')
    .toLowerCase()
    .replace(/^\/api\/v1(?=\/|$)/, '');
  const segs = path.split('/').filter(Boolean);
  let best: { group: HttpRateLimitGroup; literals: number } | undefined;
  for (const r of COMPILED) {
    if (r.method !== m || r.segments.length !== segs.length) continue;
    let literals = 0;
    let ok = true;
    for (let i = 0; i < segs.length; i += 1) {
      const t = r.segments[i];
      if (t === null) continue;
      if (t !== segs[i]) {
        ok = false;
        break;
      }
      literals += 1;
    }
    if (ok && (!best || literals > best.literals)) best = { group: r.group, literals };
  }
  return best?.group;
}

const WINDOW_MS = 60_000;
const MAX_KEYS = 50_000;

/** Счётчики фиксированного окна 1 мин в памяти процесса (08 §2.9: хранилище `memory`). */
export class MemoryWindowCounter {
  private readonly counters = new Map<string, { windowStart: number; count: number }>();

  /** `retryAfterSec` > 0 — лимит исчерпан (счётчик не увеличивается). */
  consume(key: string, limit: number, nowMs: number): { allowed: boolean; remaining: number; retryAfterSec: number } {
    const windowStart = Math.floor(nowMs / WINDOW_MS) * WINDOW_MS;
    let c = this.counters.get(key);
    if (!c || c.windowStart !== windowStart) {
      if (this.counters.size >= MAX_KEYS) this.prune(windowStart);
      c = { windowStart, count: 0 };
      this.counters.set(key, c);
    }
    if (c.count + 1 > limit) {
      return {
        allowed: false,
        remaining: 0,
        retryAfterSec: Math.max(1, Math.ceil((windowStart + WINDOW_MS - nowMs) / 1000)),
      };
    }
    c.count += 1;
    return { allowed: true, remaining: limit - c.count, retryAfterSec: 0 };
  }

  private prune(currentWindow: number): void {
    for (const [k, v] of this.counters) if (v.windowStart !== currentWindow) this.counters.delete(k);
  }
}

/**
 * Лимиты RL-READ / RL-SEARCH / RL-CART / RL-FIN (08 §2.9) — интерцептор приложения после guard'ов (субъект известен);
 * анонимные запросы этих групп до сюда не доходят (AuthGuard → 401). Превышение → 429 `RATE_LIMITED` с
 * `Retry-After` и `X-RateLimit-*`.
 */
@Injectable()
export class HttpRateLimitInterceptor implements NestInterceptor {
  private readonly limits: Readonly<Record<HttpRateLimitGroup, number>>;
  private readonly counter = new MemoryWindowCounter();

  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    @Optional() @Inject(HTTP_RATE_LIMITS) limits?: Partial<Record<HttpRateLimitGroup, number>>,
  ) {
    this.limits = { ...HTTP_RATE_LIMITS_PER_MINUTE, ...limits };
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();
    const req = context.switchToHttp().getRequest<RequestWithContext & { path?: string }>();
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal)) return next.handle();
    const group = httpRateLimitGroup(req.method ?? 'GET', req.originalUrl ?? req.url ?? req.path ?? '');
    if (!group) return next.handle();
    const limit = this.limits[group];
    const r = this.counter.consume(`${group}:${principal.userId}`, limit, this.clock.now().getTime());
    if (!r.allowed) {
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Слишком много запросов. Повторите позже.',
        retryAfter: r.retryAfterSec,
        headers: { 'X-RateLimit-Limit': String(limit), 'X-RateLimit-Remaining': '0' },
      });
    }
    return next.handle();
  }
}

/** Подключение к API (`AppModule`); требует `CLOCK` (AuthCoreModule). */
@Module({ providers: [{ provide: APP_INTERCEPTOR, useClass: HttpRateLimitInterceptor }] })
export class HttpRateLimitModule {}
