import { Body, Controller, Header, HttpCode, Logger, Post, Req } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { Idempotent } from '../common/idempotency/idempotent.decorator.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import { RequirePermission } from '../common/rbac/rbac.decorators.js';
import { kioskTabletOf } from '../kiosk/common/kiosk-tablet.reader.js';
import { CartActorResolver } from './cart-actor.js';
import { isUuidString, validationFailed } from './cart-common.js';
import { CartService } from './cart.service.js';

type Req = RequestWithContext & { ip?: string };

const BODY_FIELDS: ReadonlySet<string> = new Set(['cartId']);

/**
 * Разбор тела `POST /kiosk/reset` (OpenAPI `KioskResetRequest`, `additionalProperties: false`; 08 §4.25.4): только
 * `cartId` (UUID, rule `uuid`); иные поля → `400 VALIDATION_FAILED` rule `forbidden_field` (как `POST /kiosk/order-otp`).
 */
export function parseKioskResetBody(raw: unknown): { readonly cartId: string } {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    validationFailed([{ field: 'body', rule: 'type', message: 'Ожидается объект JSON' }]);
  }
  const body = raw as Record<string, unknown>;
  const errors: ProblemFieldError[] = [];
  for (const k of Object.keys(body)) {
    if (!BODY_FIELDS.has(k)) errors.push({ field: k, rule: 'forbidden_field', message: 'Поле не принимается' });
  }
  const cartId = body.cartId;
  if (!isUuidString(cartId)) errors.push({ field: 'cartId', rule: 'uuid', message: 'Ожидается UUID корзины' });
  if (errors.length > 0 || !isUuidString(cartId)) validationFailed(errors);
  return { cartId: cartId.toLowerCase() };
}

/**
 * `POST /kiosk/reset` (08 §4.25.4; OpenAPI `kiosk_reset`; 10 KIOSK-020; 04 FLOW-045; ADR-115) — сброс планшета
 * магазина: новая пустая корзина, корзина `cartId` закрыта, коды `kiosk_order` планшета погашены. Контроллер модуля
 * `cart` (06 §7.4, MOD-030): сброс корзины планшета без `rowVersion` — операция корзины (`CartService.resetForKiosk`).
 * Требование — `cart.manage.own` **и** `kiosk.order.submit` (оба кода вместе, 08 §4.25 «Закрытый список»; второй
 * засчитывается только `kind=kiosk`, 11 SEC-138), маршрут — в закрытом списке `KioskAccessGuard` (`KIOSK_MODE=false`
 * → `403 KIOSK_DISABLED`, вне сети магазина → `403 KIOSK_NETWORK_DENIED` до обработчика). Лимит — RL-CART;
 * `Idempotency-Key` необязателен (повтор по `cartId` идемпотентен и без него). Журнал — `kiosk.session_reset`
 * (11 §6.1: `tabletId`, `cartId`, `reason`; без номера, кода и сумм).
 */
@ApiTags('kiosk')
@Controller('kiosk')
export class KioskResetController {
  private readonly logger = new Logger('kiosk');

  constructor(
    private readonly carts: CartService,
    private readonly actors: CartActorResolver,
  ) {}

  @Post('reset')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('cart.manage.own', 'kiosk.order.submit')
  @Idempotent({ required: false })
  async reset(@Req() req: Req, @Body() raw: unknown): Promise<Record<string, unknown>> {
    // Планшет запроса кладёт KioskAccessGuard только для kind=kiosk с действующей строкой store_tablets.
    const tablet = kioskTabletOf(req);
    if (!tablet) throw new ProblemException('FORBIDDEN', { detail: 'Операция доступна только планшету магазина.' });
    const { cartId } = parseKioskResetBody(raw);
    const requestId = typeof req.id === 'string' ? req.id : null;
    const a = await this.actors.fromPrincipal(req.principal, requestId);
    const r = await this.carts.resetForKiosk(a, auditContextFromRequest(req), tablet.tabletId, cartId);
    this.logger.log(
      {
        event: 'kiosk.session_reset',
        requestId,
        tabletId: tablet.tabletId,
        cartId,
        reason: r.closedCartId === null ? 'already_closed' : 'kiosk_reset',
      },
      'kiosk.session_reset',
    );
    return r.cart;
  }
}
