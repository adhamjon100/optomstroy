import { Global, Module } from '@nestjs/common';
import { AuditAnchorService } from './audit-anchor.service.js';
import { AuditService } from './audit.service.js';

/** common/audit (D-36; 07 §9; 11 §7): AuditService (запись `level='app'`), AuditAnchorService (якоря, проверка). */
@Global()
@Module({ providers: [AuditService, AuditAnchorService], exports: [AuditService, AuditAnchorService] })
export class AuditModule {}
