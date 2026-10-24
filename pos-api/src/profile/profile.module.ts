import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { ConsentRevocationNotifier } from './consents/consent-revocation.notifier.js';
import { ConsentsRepository } from './consents/consents.repository.js';
import { ConsentsService } from './consents/consents.service.js';
import { MeConsentsService } from './consents/me-consents.service.js';
import { CustomerLinkReader } from './customer-link.reader.js';
import { MeSecurityController } from './me-security.controller.js';
import { MeController } from './me.controller.js';
import { MeService } from './me/me.service.js';
import { PhoneChangeService } from './phone-change.service.js';
import { AppPinWriter } from './pin/app-pin.writer.js';
import { ProfileService } from './profile.service.js';
import { SecurityService } from './security.service.js';
import { ProfileStepUpGuard } from './step-up/step-up.guard.js';

/**
 * Модуль D-06 `profile` (06 §7.4; 08 §4.3; RM-D-004, RM-D-014): `/me`, профиль, настройки, PIN, биометрия, согласия,
 * смена телефона. Импортирует `auth` (06 §7.4: «смена телефона — через OtpService модуля auth, PIN — через auth»):
 * StepUpService (проверка `X-Step-Up-Token`), OtpService (`phone_change_new`), AppPinsRepository (чтение `app_pins`).
 * Общий фундамент (common/auth, common/crypto, common/audit, src/users) — глобальные модули. Экспорт для
 * `registration`: `MeService`, `ConsentsService`, `AppPinWriter`, `CustomerLinkReader` (обратного импорта нет).
 */
@Module({
  imports: [AuthModule],
  controllers: [MeController, MeSecurityController],
  providers: [
    AppPinWriter,
    ConsentsRepository,
    ConsentsService,
    ConsentRevocationNotifier,
    MeConsentsService,
    CustomerLinkReader,
    MeService,
    ProfileService,
    SecurityService,
    PhoneChangeService,
    ProfileStepUpGuard,
  ],
  exports: [MeService, ConsentsService, AppPinWriter, CustomerLinkReader],
})
export class ProfileModule {}
