import { type DynamicModule, Module } from '@nestjs/common';
import { LoggerModule } from 'nestjs-pino';
import type { DestinationStream } from 'pino';
import type { AppConfig } from '../config/app-config.js';
import { buildPinoHttpOptions } from './logger.config.js';

/** pino + pino-http (nestjs-pino). `stream` — только для тестов (перехват строк лога, logging_redaction.spec.ts). */
@Module({})
export class LoggingModule {
  static forRoot(config: Pick<AppConfig, 'LOG_LEVEL' | 'APP_ENV'>, stream?: DestinationStream): DynamicModule {
    return {
      module: LoggingModule,
      imports: [LoggerModule.forRoot({ pinoHttp: buildPinoHttpOptions(config, stream) })],
      exports: [LoggerModule],
    };
  }
}
