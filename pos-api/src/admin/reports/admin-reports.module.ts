import { Module } from '@nestjs/common';
import { AdminReportsController } from './admin-reports.controller.js';
import { AdminReportsService } from './admin-reports.service.js';

/**
 * Отчёты руководителя модуля `admin` (08 §4.18.8; RM-G-006): сводка продаж, долги (снимок 1С), сверка QR. Только
 * чтение; зависимости — глобальные модули фундамента (DatabaseModule, ConfigModule, AuditModule, SettingsModule,
 * AuthCoreModule — `CLOCK`).
 */
@Module({
  controllers: [AdminReportsController],
  providers: [AdminReportsService],
  exports: [AdminReportsService],
})
export class AdminReportsModule {}
