import { Body, Controller, Header, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { clientIp, requestIdOf, type AuthHttpRequest } from '../../auth/common/request.js';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { IgnoreIdempotencyKeyGuard } from '../../common/idempotency/ignore-idempotency-key.guard.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { kioskTabletOf } from '../common/kiosk-tablet.reader.js';
import { type KioskOrderOtpResponse, KioskOtpService, parseKioskOrderOtpBody } from './kiosk-otp.service.js';

/**
 * `POST /kiosk/order-otp` (08 §4.25.1; OpenAPI `kiosk_order_otp_request`; ADR-115): код `kiosk_order` на номер
 * покупателя для отправки заявки с планшета (SCR-52 «Получить код», FLOW-044). Только `kind=kiosk`: право
 * `kiosk.order.submit` засчитывается только планшету (11 SEC-138), маршрут — в закрытом списке `KioskAccessGuard`
 * (`KIOSK_MODE=false` → `403 KIOSK_DISABLED` до обработчика). Номер — только в теле, ключ идемпотентности не
 * применяется (новый запрос — новый код; заголовок `Idempotency-Key` снимает `IgnoreIdempotencyKeyGuard`, номер не
 * попадает в `idempotency_keys`), лимиты — `RateLimitService` в `OtpService` (RL-OTP-SEND номера,
 * RL-OTP-KIOSK планшета, RL-OTP-GLOBAL; HTTP-лимиты IP и устройства к маршруту не применяются).
 */
@ApiTags('kiosk')
@Controller('kiosk')
export class KioskOtpController {
  constructor(private readonly service: KioskOtpService) {}

  @Post('order-otp')
  @HttpCode(202)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.order.submit')
  @UseGuards(IgnoreIdempotencyKeyGuard)
  async orderOtp(@Req() req: AuthHttpRequest, @Body() raw: unknown): Promise<KioskOrderOtpResponse> {
    // Планшет запроса кладёт KioskAccessGuard только для kind=kiosk с действующей строкой store_tablets.
    const tablet = kioskTabletOf(req);
    const principal = req.principal;
    if (!tablet || !isAuthenticatedPrincipal(principal)) {
      throw new ProblemException('FORBIDDEN', { detail: 'Операция доступна только планшету магазина.' });
    }
    const body = parseKioskOrderOtpBody(raw);
    return this.service.request({
      tablet,
      body,
      // device_key планшета (= X-Device-Id = claim deviceId): статус SMS — GET /auth/otp/challenges/{id} (08 §4.1.9).
      deviceKey: principal.deviceId,
      ip: clientIp(req),
      requestId: requestIdOf(req),
      audit: auditContextFromRequest(req),
    });
  }
}
