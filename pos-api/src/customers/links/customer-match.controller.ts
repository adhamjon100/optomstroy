import { Body, Controller, Get, HttpCode, Post, Req } from '@nestjs/common';
import { ApiExcludeEndpoint } from '@nestjs/swagger';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser, Public } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerMatchResolveRequest } from './customer-links.dto.js';
import { CustomerLinksService, type RegistrationCustomerMatchDto } from './customer-links.service.js';

/**
 * SCR-06 «Привязка к клиенту 1С» (08 §4.2.2, §4.2.4; 09 §7.9; 11 код 75, SEC-130):
 * - `GET /registration/customer-match` — статус привязки текущего пользователя без финансов (`profile.manage.own`,
 *   включая `pending_activation`; для `staff` — всегда `none`);
 * - `POST /registration/customer-match/confirm|reject` — самоподтверждение клиентом (`customer.link.self_resolve`,
 *   без step-up, только при `CUSTOMER_SELF_SERVICE=true`);
 * - `POST /registration/customer-match` → `405 METHOD_NOT_ALLOWED` (заголовок `Allow: GET`) (13 RM-D-005 критерий 4; путь — только
 *   GET, 13 RM-B-003).
 *
 * Маршруты размещены в `customers/links` (владелец привязок, RM-D-005); путь `/registration/*` — контракт 08.
 */
@Controller('registration/customer-match')
export class CustomerMatchController {
  constructor(private readonly service: CustomerLinksService) {}

  @Get()
  @RequirePermission('profile.manage.own')
  get(@CurrentUser() principal: AuthenticatedPrincipal): Promise<RegistrationCustomerMatchDto> {
    return this.service.getMatch(principal);
  }

  @Post()
  @Public()
  @ApiExcludeEndpoint() // не операция контракта: только ответ 405 (экспорт OpenAPI ⊆ контракт, RM-C-005 п. 5)
  methodNotAllowed(): never {
    throw new ProblemException('METHOD_NOT_ALLOWED', {
      detail: 'Маршрут поддерживает только GET.',
      headers: { Allow: 'GET' },
    });
  }

  @Post('confirm')
  @HttpCode(200)
  @RequirePermission('customer.link.self_resolve')
  @Idempotent({ required: false })
  confirm(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Body() body: CustomerMatchResolveRequest,
  ): Promise<RegistrationCustomerMatchDto> {
    return this.service.selfResolve(principal, auditContextFromRequest(req), body.linkId.toLowerCase(), 'confirm');
  }

  @Post('reject')
  @HttpCode(200)
  @RequirePermission('customer.link.self_resolve')
  @Idempotent({ required: false })
  reject(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Body() body: CustomerMatchResolveRequest,
  ): Promise<RegistrationCustomerMatchDto> {
    return this.service.selfResolve(principal, auditContextFromRequest(req), body.linkId.toLowerCase(), 'reject');
  }
}
