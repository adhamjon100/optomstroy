import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

/** Схемы ответа 08 §4.19.1 (contracts/openapi: HealthLiveness, HealthReadiness, HealthReadinessFailed). */
export class HealthLiveness {
  @ApiProperty({ enum: ['ok'] })
  status!: 'ok';

  @ApiProperty({ example: '1.0' })
  apiVersion!: string;

  @ApiProperty({ format: 'date-time' })
  serverTime!: string;
}

export class HealthSyncCheck {
  @ApiPropertyOptional({ type: 'integer', minimum: 0 })
  stockAgeSec?: number;

  @ApiPropertyOptional()
  stale?: boolean;
}

export class HealthReadinessChecks {
  @ApiPropertyOptional({ example: 'ok' })
  db?: string;

  @ApiPropertyOptional({ example: 'ok' })
  worker?: string;

  @ApiPropertyOptional({ type: HealthSyncCheck })
  sync?: HealthSyncCheck;
}

export class HealthReadiness {
  @ApiProperty({ enum: ['ok', 'degraded'] })
  status!: 'ok' | 'degraded';

  @ApiProperty({ type: HealthReadinessChecks })
  checks!: HealthReadinessChecks;
}

export class HealthReadinessFailed {
  @ApiProperty({ enum: ['failed'] })
  status!: 'failed';
}
