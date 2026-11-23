import { Module } from '@nestjs/common';
import { HelloKeyService } from '../../auth/sessions/hello-key.service.js';
import { IgnoreIdempotencyKeyGuard } from '../../common/idempotency/ignore-idempotency-key.guard.js';
import { AdminInvitationsModule } from '../invitations/admin-invitations.module.js';
import { AdminUsersController } from './admin-users.controller.js';
import { AdminUsersService } from './admin-users.service.js';
import { EmergencyLoginCodeController } from './emergency-code/emergency-code.controller.js';
import { EmergencyCodeRepository } from './emergency-code/emergency-code.repository.js';
import { EmergencyLoginCodeService } from './emergency-code/emergency-code.service.js';
import { AdminSharedModule } from './shared/admin-shared.module.js';

/**
 * Администрирование пользователей (RM-D-006, RM-D-016; 08 §4.18.1–§4.18.3, §4.18.9, §4.18.10). Подключение —
 * `imports: [AdminUsersModule]` в src/admin/admin.module.ts (владелец каркаса); модуль приглашений входит сюда.
 * Вход по аварийному коду — модуль auth (`EmergencyLoginService`); здесь только выдача (RM-D-016).
 * `HelloKeyService` (правила и отзыв ключей Windows Hello, ADR-116) — своим провайдером: зависит только от глобальных
 * провайдеров (users, аудит, часы, конфигурация), импорта `AuthModule` нет (06 MOD-022: `auth` не импортирует `admin`).
 */
@Module({
  imports: [AdminSharedModule, AdminInvitationsModule],
  controllers: [AdminUsersController, EmergencyLoginCodeController],
  providers: [
    AdminUsersService,
    EmergencyCodeRepository,
    EmergencyLoginCodeService,
    IgnoreIdempotencyKeyGuard,
    HelloKeyService,
  ],
  exports: [AdminUsersService, EmergencyLoginCodeService, AdminInvitationsModule],
})
export class AdminUsersModule {}
