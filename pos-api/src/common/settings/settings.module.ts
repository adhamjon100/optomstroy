import { Global, Module } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../db/database.module.js';
import { SettingsReader } from './settings-reader.js';

@Global()
@Module({
  providers: [{ provide: SettingsReader, inject: [PG_POOL], useFactory: (pool: pg.Pool) => new SettingsReader(pool) }],
  exports: [SettingsReader],
})
export class SettingsModule {}
