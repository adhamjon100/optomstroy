import { Module } from '@nestjs/common';
import { AdminAuditModule } from './audit/admin-audit.module.js';
// RM-G-003 (агент G-be-credit): лимиты ручной скидки по ролям `/admin/discount-limits`.
import { AdminDiscountLimitsModule } from './discount-limits/admin-discount-limits.module.js';
import { AdminReportsModule } from './reports/admin-reports.module.js';
import { AdminSettingsModule } from './settings/admin-settings.module.js';
import { AdminRateLimitModule } from './shared/admin-rate-limit.js';
import { AdminUsersModule } from './users/index.js';

/**
 * Модуль D-06 `admin` (06 §7.4). Этап D: пользователи, роли, блокировка, сброс PIN, аварийный код входа и
 * приглашения сотрудников (RM-D-006, RM-D-016, RM-D-017; `AdminUsersModule` включает `AdminInvitationsModule`);
 * настройки системы `/admin/settings` (08 §4.18.6; RM-D-015 п. 2 — `AdminSettingsModule`). Этап G (RM-G-006):
 * журнал аудита `/admin/audit-logs` и порт `AuditQueryPort` (`AdminAuditModule`), отчёты руководителя
 * `/admin/reports/*` (`AdminReportsModule`).
 * Правила импорта (MOD-022) — 06 §7.4 «Запрещены циклы».
 */
@Module({
  // RL-ADMIN (08 §2.9; DQ-01): лимит группы `/admin/*`, `POST /sync/*`, `POST /orders/{id}/onec-link`.
  imports: [
    AdminRateLimitModule,
    AdminUsersModule,
    AdminSettingsModule,
    AdminAuditModule,
    AdminReportsModule,
    AdminDiscountLimitsModule,
  ],
  exports: [AdminUsersModule, AdminSettingsModule, AdminAuditModule, AdminReportsModule],
})
export class AdminModule {}
