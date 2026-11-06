import { Body, Controller, Get, Header, HttpCode, Post, Query, Req, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { headerValue, requestIdOf, type AuthHttpRequest } from '../../auth/common/request.js';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { IDEMPOTENCY_KEY_HEADER, Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { type KioskTabletContext, kioskTabletOf } from '../common/kiosk-tablet.reader.js';
import {
  type KioskOrderAccepted,
  KioskOrderService,
  kioskForbiddenMoneyFields,
  parseKioskOrdersBody,
  parseKioskOrdersQuery,
} from './kiosk-order.service.js';

interface StatusResponse {
  status(code: number): unknown;
}

/** Планшет запроса кладёт KioskAccessGuard только для kind=kiosk с действующей строкой store_tablets. */
function tabletOrDeny(req: AuthHttpRequest): KioskTabletContext {
  const tablet = kioskTabletOf(req);
  if (!tablet || !isAuthenticatedPrincipal(req.principal)) {
    throw new ProblemException('FORBIDDEN', { detail: 'Операция доступна только планшету магазина.' });
  }
  return tablet;
}

/**
 * `POST /kiosk/orders` и `GET /kiosk/orders?idempotencyKey=` (08 §4.25.2, §4.25.3; OpenAPI `kiosk_orders_create`,
 * `kiosk_orders_find`; ADR-115): заявка с планшета магазина в три шага и номер заявки по ключу последней попытки
 * (SCR-52, FLOW-044, A4). Только `kind=kiosk`: право `kiosk.order.submit` засчитывается только планшету (11 SEC-138),
 * маршруты — в закрытом списке `KioskAccessGuard` (`KIOSK_MODE=false` → `403 KIOSK_DISABLED`, вне сети магазина →
 * `403 KIOSK_NETWORK_DENIED` — до обработчика). `Idempotency-Key` у `POST` обязателен и новый на каждую попытку
 * (08 §2.7); лимиты — RL-FIN (`POST`) и RL-READ (`GET`). Ответ — только `{publicNumber}` (`KioskOrderAccepted`).
 */
@ApiTags('kiosk')
@Controller('kiosk')
export class KioskOrdersController {
  constructor(private readonly service: KioskOrderService) {}

  /** `201` — синхронная проверка 1С выполнена; `202` — нет (заявка `submitting`, outbox повторяет). */
  @Post('orders')
  @HttpCode(201)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.order.submit')
  @Idempotent({ required: true })
  async create(
    @Req() req: AuthHttpRequest,
    @Res({ passthrough: true }) res: StatusResponse,
    @Body() raw: unknown,
  ): Promise<KioskOrderAccepted> {
    const tablet = tabletOrDeny(req);
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal)) throw new ProblemException('FORBIDDEN');
    const audit = auditContextFromRequest(req);
    const money = kioskForbiddenMoneyFields(raw);
    if (money.length > 0) {
      await this.service.auditPriceOverride(audit, money);
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: money.map((f): ProblemFieldError => ({
          field: f,
          rule: 'forbidden_field',
          message: 'Поле не принимается: суммы считает сервер.',
        })),
      });
    }
    const body = parseKioskOrdersBody(raw);
    // Наличие и формат ключа проверил IdempotencyInterceptor (`@Idempotent({ required: true })`).
    const idempotencyKey = headerValue(req, IDEMPOTENCY_KEY_HEADER);
    if (!idempotencyKey) throw new ProblemException('INTERNAL');
    const r = await this.service.create({
      req,
      principal,
      tablet,
      body,
      idempotencyKey,
      requestId: requestIdOf(req),
      audit,
    });
    res.status(r.httpStatus);
    return { publicNumber: r.publicNumber };
  }

  @Get('orders')
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.order.submit')
  async find(@Req() req: AuthHttpRequest, @Query() q: Record<string, unknown>): Promise<KioskOrderAccepted> {
    const tablet = tabletOrDeny(req);
    return this.service.findByIdempotencyKey(tablet, parseKioskOrdersQuery(q));
  }
}
