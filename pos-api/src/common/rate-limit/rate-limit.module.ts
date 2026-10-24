import { Global, Module } from '@nestjs/common';
import { RateLimitService } from './rate-limit.service.js';

/** common/rate-limit (D-44; 07 §5.12): счётчики в PostgreSQL. Требует `CLOCK` (AuthCoreModule) и `DRIZZLE`. */
@Global()
@Module({ providers: [RateLimitService], exports: [RateLimitService] })
export class RateLimitModule {}
