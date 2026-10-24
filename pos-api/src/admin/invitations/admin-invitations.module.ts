import { Module } from '@nestjs/common';
import { AdminSharedModule } from '../users/shared/admin-shared.module.js';
import { AdminInvitationsController } from './admin-invitations.controller.js';
import { AdminInvitationsRepository } from './admin-invitations.repository.js';
import { AdminInvitationsService } from './admin-invitations.service.js';

/** Приглашения сотрудников `/admin/invitations` (08 §4.18.4; RM-D-006, RM-D-017). */
@Module({
  imports: [AdminSharedModule],
  controllers: [AdminInvitationsController],
  providers: [AdminInvitationsRepository, AdminInvitationsService],
  exports: [AdminInvitationsService],
})
export class AdminInvitationsModule {}
