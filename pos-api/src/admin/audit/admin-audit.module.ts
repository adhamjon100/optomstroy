import { Module } from '@nestjs/common';
import { AUDIT_QUERY_PORT } from '../../common/ports/index.js';
import { bindSalesPort } from '../../sales-domain/sales-ports.module.js';
import { AdminAuditController } from './admin-audit.controller.js';
import { AuditJobsBridge } from './audit-jobs.bridge.js';
import { AuditQueryService } from './audit-query.service.js';

/**
 * Журнал аудита модуля `admin` (08 §4.18.7; RM-G-006): `GET /admin/audit-logs` и привязка порта `AuditQueryPort`
 * (`sales.AuditQueryPort`, 06 §7.4) — чтение аудита для `GET /transactions/{id}` (TXN-003) и отчётов. Зависимости —
 * глобальные модули фундамента (DatabaseModule, CryptoModule, AuditModule) и `SalesPortsModule` (реестр портов).
 */
@Module({
  controllers: [AdminAuditController],
  // `AuditJobsBridge` — задачи pos-worker `audit.anchor` / `audit.verify` (06 §7.5, 11 SEC-081; ревью G-security-1).
  providers: [...bindSalesPort(AUDIT_QUERY_PORT, AuditQueryService), AuditJobsBridge],
  exports: [AuditQueryService, AuditJobsBridge],
})
export class AdminAuditModule {}
