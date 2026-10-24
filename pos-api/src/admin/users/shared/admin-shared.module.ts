import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../../../auth/step-up/step-up-token.verifier.js';
import { AdminUsersRepository } from '../admin-users.repository.js';
import { AdminAuthzService } from './admin-authz.service.js';
import { AdminStepUpGuard } from './step-up.guard.js';

/**
 * Общие провайдеры админ-раздела пользователей и приглашений: данные (`AdminUsersRepository`), применение политики
 * целей с аудитом `authz.denied` и проверка `X-Step-Up-Token`. Зависимости — глобальные модули фундамента
 * (DatabaseModule, AuthCoreModule, AuditModule, UsersModule, CryptoModule).
 */
@Module({
  // StepUpTokenVerifier — единая проверка X-Step-Up-Token (auth, без состояния; зависимости — глобальные).
  providers: [AdminUsersRepository, AdminAuthzService, AdminStepUpGuard, StepUpTokenVerifier],
  exports: [AdminUsersRepository, AdminAuthzService, AdminStepUpGuard, StepUpTokenVerifier],
})
export class AdminSharedModule {}
