import { Module } from '@nestjs/common';
import { AuthModule } from '../../auth/auth.module.js';
import { IgnoreIdempotencyKeyGuard } from '../../common/idempotency/ignore-idempotency-key.guard.js';
import { KioskOtpController } from './kiosk-otp.controller.js';
import { KioskOtpService } from './kiosk-otp.service.js';

/**
 * Подмодуль `kiosk/otp` (06 MOD-030; ADR-115): код к заявке `POST /kiosk/order-otp` (08 §4.25.1) — через `OtpService`
 * модуля `auth` (как смена номера в `profile`, 06 §7.4), свой текст SMS (`otp_kiosk_order`, Р-21 (а)), лимиты
 * планшета (RL-OTP-KIOSK), один действующий код на планшет, каталог версий текста информирования (`notice-catalog.ts`).
 * Контроллер — `@ApiTags('kiosk')`. Сервисы другим модулям не экспортируются: погашение кодов планшета для сброса,
 * отключения, аварийного выхода и подключения заново — `OtpChallengesRepository.gashKioskCodes` модуля `auth`.
 */
@Module({
  imports: [AuthModule],
  controllers: [KioskOtpController],
  providers: [KioskOtpService, IgnoreIdempotencyKeyGuard],
})
export class KioskOtpModule {}
