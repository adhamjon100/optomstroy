import { Body, Controller, Header, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { AuthHttpRequest } from '../../auth/common/request.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { IgnoreIdempotencyKeyGuard } from '../../common/idempotency/ignore-idempotency-key.guard.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { kioskTabletOf } from '../common/kiosk-tablet.reader.js';
import { KioskExitService, parseKioskExitBody } from './kiosk-exit.service.js';

/**
 * `POST /kiosk/exit` (08 §4.25.5; OpenAPI `kiosk_exit`; 11 SEC-140; ADR-115): аварийный выход со связью — долгое
 * нажатие на логотип, экранные кнопки, аварийный код из 8 цифр. Только `kind=kiosk`: право `kiosk.self.exit`
 * засчитывается только планшету (11 SEC-138), маршрут — в закрытом списке `KioskAccessGuard` (`KIOSK_MODE=false` →
 * `403 KIOSK_DISABLED`, адрес вне сети магазина → `403 KIOSK_NETWORK_DENIED` — до обработчика; приложение тогда
 * проверяет код на устройстве). Ключ идемпотентности не применяется (повтор после потерянного `200` — `401
 * KIOSK_REVOKED`); заголовок Idempotency-Key снимается guard'ом: код не попадает в idempotency_keys (11 SEC-140 п. 6;
 * `IgnoreIdempotencyKeyGuard`); лимит — счётчик неверных кодов `store_tablets.exit_failed_attempts` (RL-PIN, 08 §2.9).
 */
@ApiTags('kiosk')
@Controller('kiosk')
export class KioskExitController {
  constructor(private readonly service: KioskExitService) {}

  @Post('exit')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.self.exit')
  @UseGuards(IgnoreIdempotencyKeyGuard)
  async exit(@Req() req: AuthHttpRequest, @Body() raw: unknown): Promise<Record<string, never>> {
    // Планшет запроса кладёт KioskAccessGuard только для kind=kiosk с действующей строкой store_tablets.
    const tablet = kioskTabletOf(req);
    if (!tablet || !isAuthenticatedPrincipal(req.principal)) {
      throw new ProblemException('FORBIDDEN', { detail: 'Операция доступна только планшету магазина.' });
    }
    await this.service.exit(req, tablet, parseKioskExitBody(raw));
    return {};
  }
}
