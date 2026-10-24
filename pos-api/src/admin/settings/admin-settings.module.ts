import { Module } from '@nestjs/common';
import { AdminSharedModule } from '../users/shared/admin-shared.module.js';
import { AdminSettingsController } from './admin-settings.controller.js';
import { AdminSettingsRepository } from './admin-settings.repository.js';
import { AdminSettingsService } from './admin-settings.service.js';

/**
 * Настройки системы `/admin/settings` (08 §4.18.6; RM-D-015 п. 2). Зависимости — AdminSharedModule (step-up) и
 * глобальные модули фундамента (DatabaseModule, AuditModule, SettingsModule, ConfigModule). Публичная проекция
 * `GET /settings/public` — модуль `settings` (src/settings), он читает те же ключи через SettingsReader.
 */
@Module({
  imports: [AdminSharedModule],
  controllers: [AdminSettingsController],
  providers: [AdminSettingsService, AdminSettingsRepository],
  exports: [AdminSettingsService],
})
export class AdminSettingsModule {}
