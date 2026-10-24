import { Module } from '@nestjs/common';
import { PublicSettingsController } from './public-settings.controller.js';
import { PublicSettingsService } from './public-settings.service.js';

/**
 * Модуль `settings` — публичные настройки для аутентифицированных (08 §4.23; RM-D-015). Зависимости — глобальные
 * ConfigModule, SettingsModule (common/settings), AppVersionModule, RbacModule. Подключение — в AppModule
 * (`DOMAIN_MODULES`, интеграция — владелец app.module).
 */
@Module({
  controllers: [PublicSettingsController],
  providers: [PublicSettingsService],
  exports: [PublicSettingsService],
})
export class PublicSettingsModule {}
