import { type CallHandler, type ExecutionContext, Injectable, type NestInterceptor } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Response } from 'express';
import { type Observable, tap } from 'rxjs';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RECORDS_RECENT_VIEW } from '../common/recent-view.marker.js';
import { RecentProductsService } from './recent-products.service.js';

export { RECORDS_RECENT_VIEW, RecordsRecentView } from '../common/recent-view.marker.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Побочный эффект карточки товара `GET /catalog/products/{id}` (08 §4.4.3): «запись в `recent_products`
 * (пользователь, товар, время) — асинхронно, не влияет на ответ». Обработчик помечается `@RecordsRecentView()`
 * (`src/catalog/common/recent-view.marker.ts`); интерсептор регистрируется глобально (APP_INTERCEPTOR в
 * `CatalogRecentModule`) и срабатывает только на помеченных обработчиках — так контроллер каталога не импортирует
 * модуль «Недавних» (интеграция этапа E, EQ-CSYNC-06). Отметка — после успешного ответа (2xx/304), параметр пути
 * `id`. Ошибка карточки (404 для `customer`, 403) отметку не создаёт.
 */
@Injectable()
export class RecentViewInterceptor implements NestInterceptor {
  constructor(
    private readonly recent: RecentProductsService,
    private readonly reflector: Reflector,
  ) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();
    const marked = this.reflector.getAllAndOverride<boolean | undefined>(RECORDS_RECENT_VIEW, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (marked !== true) return next.handle();
    const http = context.switchToHttp();
    const req = http.getRequest<RequestWithContext>();
    const res = http.getResponse<Response>();
    return next.handle().pipe(
      tap(() => {
        const id = req.params?.id;
        const principal = req.principal;
        if (!principal || typeof id !== 'string' || !UUID_RE.test(id)) return;
        if (res.statusCode >= 400) return;
        this.recent.recordViewInBackground(principal.userId, id.toLowerCase());
      }),
    );
  }
}
