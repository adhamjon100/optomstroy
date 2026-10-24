import { Module } from '@nestjs/common';
import { HealthController } from './health.controller.js';
import { HealthService } from './health.service.js';
import { OpenApiController } from './openapi.controller.js';
import { OPENAPI_DOCUMENT } from './openapi.document.js';
import { StubSyncFreshnessProbe, SYNC_FRESHNESS_PROBE } from './sync-freshness.probe.js';

/** Модуль D-06 `health`: liveness/readiness и `/openapi.json` (06 §7.4). */
@Module({
  controllers: [HealthController, OpenApiController],
  providers: [
    HealthService,
    { provide: SYNC_FRESHNESS_PROBE, useClass: StubSyncFreshnessProbe },
    // Документ строится после инициализации приложения (create-app.ts) и кладётся в current.
    { provide: OPENAPI_DOCUMENT, useValue: {} },
  ],
  exports: [OPENAPI_DOCUMENT],
})
export class HealthModule {}
