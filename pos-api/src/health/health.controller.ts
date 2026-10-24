import { Controller, Get, Res } from '@nestjs/common';
import { ApiOkResponse, ApiOperation, ApiServiceUnavailableResponse, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { Public } from '../common/rbac/rbac.decorators.js';
import { HealthLiveness, HealthReadiness, HealthReadinessFailed } from './health.dto.js';
import { HealthService, type ReadinessResult } from './health.service.js';

/**
 * `GET /health` (liveness) и `GET /health/ready` (readiness) — 08 §4.19.1, ядро §16 п. 8. Публичные, вне префикса
 * `/api/v1` (pos-proxy: `handle /health*`, healthcheck compose `http://localhost:3000/health`), без проверки версии
 * клиента. Ответ 503 readiness — `application/json {status: failed}`, не problem+json.
 */
@ApiTags('health')
@Public()
@Controller('health')
export class HealthController {
  constructor(private readonly health: HealthService) {}

  @Get()
  @ApiOperation({ operationId: 'health_liveness_get', summary: 'Liveness' })
  @ApiOkResponse({ type: HealthLiveness, description: 'Процесс жив.' })
  liveness(): HealthLiveness {
    return this.health.liveness();
  }

  @Get('ready')
  @ApiOperation({ operationId: 'health_readiness_get', summary: 'Readiness' })
  @ApiOkResponse({ type: HealthReadiness, description: 'Готов (ok) или работает с деградацией (degraded).' })
  @ApiServiceUnavailableResponse({ type: HealthReadinessFailed, description: 'Не готов: недоступна БД или worker.' })
  async readiness(@Res({ passthrough: true }) res: Response): Promise<ReadinessResult> {
    const result = await this.health.readiness();
    if (result.status === 'failed') res.status(503);
    return result;
  }
}
