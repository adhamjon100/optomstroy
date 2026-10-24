import { Global, Module } from '@nestjs/common';
import { PgIdempotencyStore } from './idempotency.repository.js';
import { IdempotencyService } from './idempotency.service.js';
import { IDEMPOTENCY_STORE } from './idempotency.store.js';

@Global()
@Module({
  providers: [{ provide: IDEMPOTENCY_STORE, useClass: PgIdempotencyStore }, IdempotencyService],
  exports: [IDEMPOTENCY_STORE, IdempotencyService],
})
export class IdempotencyModule {}
