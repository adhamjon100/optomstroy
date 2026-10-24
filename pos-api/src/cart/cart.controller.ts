import { Body, Controller, Delete, Get, Header, HttpCode, Param, Patch, Post, Put, Query, Req } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { type AuditContext, auditContextFromRequest } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { isAuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { Idempotent } from '../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { RequireAnyPermission, RequirePermission } from '../common/rbac/rbac.decorators.js';
import { CartActorResolver } from './cart-actor.js';
import { fieldError, singleQuery, UUID_RE, uuidPath, validationFailed } from './cart-common.js';
import {
  forbiddenPriceFields,
  parseCustomerSet,
  parseDiscount,
  parsePark,
  parsePreview,
  parsePutItem,
  parseResume,
  parseUpdate,
} from './cart-requests.js';
import { CART_MAX_ITEMS, CartService, PARKED_PAGE_DEFAULT, type StepUpCheck } from './cart.service.js';
import { CheckoutService } from './checkout.service.js';

type Req = RequestWithContext & { ip?: string };
type Dto = Record<string, unknown>;

const NO_STORE = 'no-store';

/**
 * Модуль `cart` (08 §4.7; OpenAPI pos-api.v1.yaml 1.1.0, теги `cart`): корзина, отложенные корзины, ручная скидка,
 * клиент корзины, смена склада, предпросмотр оформления. Права — `cart.manage.own` (+ `discount.*`, `cart.parked.*`,
 * `order.create`; 11 §4.3), только своя корзина; `customer` — режим клиента (ядро §24.2; без отложенных корзин и
 * ручной скидки). Лимит частоты — RL-CART (common/rate-limit). `Cache-Control: no-store`. Цены клиент не передаёт:
 * попытка → `400 VALIDATION_FAILED` (`forbidden_field`) + аудит `price.override_attempt` (10 DISC-011).
 */
@Controller('cart')
export class CartController {
  constructor(
    private readonly carts: CartService,
    private readonly checkout: CheckoutService,
    private readonly actors: CartActorResolver,
    private readonly audit: AuditService,
    private readonly stepUpTokens: StepUpTokenVerifier,
  ) {}

  @Get()
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  async get(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Dto> {
    const raw = singleQuery(q, 'revalidate');
    if (raw !== undefined && raw !== 'true' && raw !== 'false') {
      fieldError('revalidate', 'type', 'Параметр revalidate должен быть true или false.');
    }
    return this.carts.get(await this.actor(req), raw !== 'false');
  }

  @Delete()
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  async clear(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Dto> {
    const raw = singleQuery(q, 'rowVersion');
    if (raw === undefined || raw === '') fieldError('rowVersion', 'required', 'Параметр rowVersion обязателен.');
    if (!/^\d{1,9}$/.test(raw)) fieldError('rowVersion', 'type', 'rowVersion — целое число ≥ 0.');
    return this.carts.clear(await this.actor(req), ctxOf(req), Number(raw));
  }

  @Patch()
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  @Idempotent({ required: false })
  async update(@Req() req: Req, @Body() body: unknown): Promise<Dto> {
    await this.rejectPriceFields(req, body);
    const r = parseUpdate(body);
    return this.carts.updateWarehouse(await this.actor(req), ctxOf(req), r.warehouseId, r.rowVersion);
  }

  @Put('items/:variantId')
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  @Idempotent({
    required: false,
    requiredWhen: (req) => {
      const b = req.body as { mode?: unknown } | undefined;
      return typeof b === 'object' && b !== null && b.mode === 'increment';
    },
  })
  async putItem(@Req() req: Req, @Param('variantId') variantId: string, @Body() body: unknown): Promise<Dto> {
    const id = uuidPath(variantId, 'variantId');
    await this.rejectPriceFields(req, body, ['priceSnapshot']);
    const r = parsePutItem(body);
    return this.carts.putItem(await this.actor(req), ctxOf(req), id, r);
  }

  @Delete('items/:variantId')
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  async deleteItem(
    @Req() req: Req,
    @Param('variantId') variantId: string,
    @Query() q: Record<string, unknown>,
  ): Promise<Dto> {
    const id = uuidPath(variantId, 'variantId');
    const raw = singleQuery(q, 'packagingId');
    let packagingId: string | null | undefined;
    if (raw === undefined) packagingId = undefined;
    else if (raw === 'null' || raw === '') packagingId = null;
    else if (UUID_RE.test(raw)) packagingId = raw.toLowerCase();
    else fieldError('packagingId', 'uuid', 'packagingId — UUID упаковки (или null — базовая единица).');
    return this.carts.deleteItem(await this.actor(req), ctxOf(req), id, packagingId);
  }

  @Post('customer')
  @HttpCode(200)
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  @Idempotent({ required: false })
  async setCustomer(@Req() req: Req, @Body() body: unknown): Promise<Dto> {
    await this.rejectPriceFields(req, body);
    const r = parseCustomerSet(body);
    return this.carts.setCustomer(await this.actor(req), ctxOf(req), r);
  }

  @Delete('customer')
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  async unsetCustomer(@Req() req: Req): Promise<Dto> {
    return this.carts.unsetCustomer(await this.actor(req), ctxOf(req));
  }

  @Post('discount')
  @HttpCode(200)
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('discount.apply.within_limit', 'discount.approve.over_limit')
  @Idempotent({ required: false })
  async discount(@Req() req: Req, @Body() body: unknown): Promise<Dto> {
    await this.rejectPriceFields(req, body);
    const r = parseDiscount(body);
    const a = await this.actor(req);
    return this.carts.applyDiscount(a, ctxOf(req), r, this.stepUp(req));
  }

  @Post('park')
  @HttpCode(201)
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own')
  @Idempotent({ required: true })
  async park(@Req() req: Req, @Body() body: unknown): Promise<{ parked: Dto; active: Dto }> {
    // 08 §2.4 (API-008): 403 FORBIDDEN раньше 400 — режим клиента отказывается до разбора тела.
    const a = await this.actor(req);
    if (a.isCustomer) throw parkedForbidden();
    const r = parsePark(body);
    return this.carts.park(a, ctxOf(req), r);
  }

  @Get('parked')
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('cart.manage.own', 'cart.parked.read.all')
  async parked(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Dto> {
    const scope = singleQuery(q, 'scope') ?? 'own';
    if (scope !== 'own' && scope !== 'all') fieldError('scope', 'enum', 'scope — own или all.');
    const rawLimit = singleQuery(q, 'limit');
    let limit = PARKED_PAGE_DEFAULT;
    if (rawLimit !== undefined && rawLimit !== '') {
      if (!/^\d{1,4}$/.test(rawLimit) || Number(rawLimit) < 1 || Number(rawLimit) > CART_MAX_ITEMS) {
        fieldError('limit', 'limit', `limit — от 1 до ${CART_MAX_ITEMS}.`);
      }
      limit = Number(rawLimit);
    }
    const cursor = singleQuery(q, 'cursor');
    const page = await this.carts.listParked(await this.actor(req), {
      scope,
      limit,
      cursor: cursor === '' ? undefined : cursor,
    });
    return { ...page };
  }

  @Delete('parked/:id')
  @HttpCode(204)
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('cart.manage.own', 'cart.parked.resume.any')
  async deleteParked(@Req() req: Req, @Param('id') id: string): Promise<void> {
    await this.carts.deleteParked(await this.actor(req), ctxOf(req), uuidPath(id, 'id'));
  }

  @Post('parked/:id/resume')
  @HttpCode(200)
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('cart.manage.own', 'cart.parked.resume.any')
  @Idempotent({ required: false })
  async resume(@Req() req: Req, @Param('id') id: string, @Body() body: unknown): Promise<Dto> {
    const a = await this.actor(req);
    if (a.isCustomer) throw parkedForbidden(); // 403 раньше 400 (08 §2.4, API-008)
    const cartId = uuidPath(id, 'id');
    const r = parseResume(body);
    return this.carts.resume(a, ctxOf(req), cartId, r.replaceActive);
  }

  @Post('checkout-preview')
  @HttpCode(200)
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('cart.manage.own', 'order.create')
  @Idempotent({ required: false })
  async preview(@Req() req: Req, @Body() body: unknown): Promise<Dto> {
    await this.rejectPriceFields(req, body);
    const r = parsePreview(body);
    return this.checkout.preview(await this.actor(req), r);
  }

  // ------------------------------------------------------------------------------------------- помощники

  private actor(req: Req) {
    return this.actors.fromPrincipal(req.principal, typeof req.id === 'string' ? req.id : null);
  }

  /** Клиент не передаёт цены и итоги (D-23; 08 §2.14): `forbidden_field` + аудит `price.override_attempt`. */
  private async rejectPriceFields(req: Req, body: unknown, exempt: readonly string[] = []): Promise<void> {
    const fields = forbiddenPriceFields(body, exempt);
    if (fields.length === 0) return;
    await this.audit
      .write(ctxOf(req), {
        action: 'price.override_attempt',
        result: 'denied',
        severity: 'warning',
        after: { fields, route: `${req.method ?? ''} ${req.route?.path ?? ''}` },
      })
      .catch(() => undefined);
    validationFailed(
      fields.map((f) => ({
        field: f,
        rule: 'forbidden_field',
        message: 'Цены и итоги считает сервер — поле не принимается.',
      })),
    );
  }

  private stepUp(req: Req): StepUpCheck {
    return async (operation: string) => {
      const p = req.principal;
      if (!isAuthenticatedPrincipal(p)) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
      const v = await this.stepUpTokens.verify(req.headers['x-step-up-token'], p, { operation });
      return v.method;
    };
  }
}

function ctxOf(req: Req): AuditContext {
  return auditContextFromRequest(req);
}

/** Отложенные корзины в режиме клиента недоступны (RM-F-015; 08 §4.7.6–§4.7.9). */
function parkedForbidden(): ProblemException {
  return new ProblemException('FORBIDDEN', { detail: 'Отложенные корзины в режиме клиента недоступны.' });
}
