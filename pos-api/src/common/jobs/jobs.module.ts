import { Global, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { PgBossService } from './pg-boss.service.js';

@Global()
@Module({
  providers: [
    {
      provide: PgBossService,
      inject: [APP_CONFIG],
      useFactory: (c: AppConfig) => new PgBossService(c.DATABASE_URL),
    },
  ],
  exports: [PgBossService],
})
export class JobsModule {}
