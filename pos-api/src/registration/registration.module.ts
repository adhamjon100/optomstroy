import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { ProfileModule } from '../profile/profile.module.js';
import { RegistrationController } from './registration.controller.js';
import { RegistrationService } from './registration.service.js';

/**
 * Модуль D-06 `registration` (06 §7.4; 08 §4.2.1; RM-D-004, RM-D-014, RM-D-017): регистрация клиента-покупателя по
 * `registration_token`, правило роли D-07 (ред. ядра §24.2), согласия, защита входа, запуск привязки к карточке 1С
 * (порт CUSTOMER_MATCHING_PORT — реализует `customers`). Импортирует `auth` (RegistrationTokenService, SessionIssuer)
 * и `profile` (Me, согласия, запись PIN); обратного импорта нет. Общий фундамент — глобальные модули.
 */
@Module({
  imports: [AuthModule, ProfileModule],
  controllers: [RegistrationController],
  providers: [RegistrationService],
  exports: [RegistrationService],
})
export class RegistrationModule {}
