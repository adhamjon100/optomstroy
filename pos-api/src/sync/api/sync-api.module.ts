import { type DynamicModule, Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import type { JobSender } from '../scheduler/sync-run.requester.js';
import { DEFAULT_SYNC_API_OPTIONS, SYNC_API_OPTIONS, SYNC_JOB_SENDER, type SyncApiOptions } from './sync-api.common.js';
import { SyncController } from './sync.controller.js';
import { SyncOutboxService } from './sync-outbox.service.js';
import { SyncRunsService } from './sync-runs.service.js';
import { SyncStatusService } from './sync-status.service.js';

/** Отправка job через экземпляр pg-boss процесса API (D-44); pg-boss не готов → 500 (запуск не принят). */
export function pgBossJobSender(boss: PgBossService): JobSender {
  return {
    send: async (name, data, options) => {
      const instance = boss.instance;
      if (!instance) throw new ProblemException('INTERNAL', { detail: 'Очередь заданий недоступна.' });
      return instance.send(name, data, options);
    },
  };
}

export interface SyncApiModuleOptions {
  readonly options?: Partial<SyncApiOptions>;
}

/**
 * HTTP API синхронизации (RM-E-002, RM-E-014): `GET /sync/status`, `POST|GET /sync/runs`, `GET /sync/runs/{id}`,
 * `GET /sync/runs/{id}/errors`, `GET /sync/outbox`, `POST /sync/outbox/{id}/retry`. Зависимости — глобальные модули
 * фундамента (Config, Database, Rbac, Crypto, Audit, AuthCore, Users, Jobs). Отправитель job — токен
 * `SYNC_JOB_SENDER` (по умолчанию pg-boss процесса API; тесты подменяют).
 */
@Module({})
export class SyncApiModule {
  static forRoot(o: SyncApiModuleOptions = {}): DynamicModule {
    return {
      module: SyncApiModule,
      controllers: [SyncController],
      providers: [
        { provide: SYNC_API_OPTIONS, useValue: { ...DEFAULT_SYNC_API_OPTIONS, ...o.options } },
        { provide: SYNC_JOB_SENDER, inject: [PgBossService], useFactory: pgBossJobSender },
        StepUpTokenVerifier,
        SyncRunsService,
        SyncStatusService,
        SyncOutboxService,
      ],
      exports: [SyncRunsService, SyncStatusService, SyncOutboxService],
    };
  }
}
