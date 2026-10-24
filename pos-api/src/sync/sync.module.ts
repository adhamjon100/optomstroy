import { Module } from '@nestjs/common';
import { SyncApiModule } from './api/sync-api.module.js';

/**
 * Модуль D-06 `sync` (06 §7.4). Этап E (RM-E-002, RM-E-014): HTTP API `/sync/*` — `SyncApiModule`.
 * Планировщик, обработчики сущностей, `onec.changes`, сверка `$count` и алерты — в процессе `pos-worker`
 * (`src/jobs/sync/sync-worker.wiring.ts`, `src/jobs/worker-runtime.ts`); конвейер apply — `src/sync/apply`.
 */
@Module({
  imports: [SyncApiModule.forRoot()],
})
export class SyncModule {}
