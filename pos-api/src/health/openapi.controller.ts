import { Controller, Get, Headers, Inject, Optional, Req, Res } from '@nestjs/common';
import { ApiExcludeEndpoint, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import { Public } from '../common/rbac/rbac.decorators.js';
import { OPENAPI_DOCUMENT, type OpenApiDocumentHolder } from './openapi.document.js';

/**
 * `GET /openapi.json` (08 §4.19.2; API-121; 16 §4.3 OPENAPI_PUBLIC): при `OPENAPI_PUBLIC=true` — публичный
 * (тестовый контур); иначе — только Bearer с правом `system.openapi.read` (admin), без него → 404 NOT_FOUND
 * (существование не раскрывается). Доступен также как `/api/v1/openapi.json` (pos-proxy проксирует `/api/*`).
 */
@ApiTags('health')
@Public()
@Controller()
export class OpenApiController {
  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'OPENAPI_PUBLIC'>,
    private readonly catalog: PermissionCatalog,
    @Optional() @Inject(OPENAPI_DOCUMENT) private readonly holder?: { current?: OpenApiDocumentHolder },
  ) {}

  @Get('openapi.json')
  @ApiOperation({ operationId: 'health_openapi_get', summary: 'Контракт OpenAPI 3.0.3' })
  @ApiOkResponse({ description: 'Документ OpenAPI.' })
  get(@Req() req: RequestWithContext, @Res() res: Response, @Headers('if-none-match') ifNoneMatch?: string): void {
    this.serve(req, res, ifNoneMatch);
  }

  @Get('api/v1/openapi.json')
  @ApiExcludeEndpoint()
  getPrefixed(
    @Req() req: RequestWithContext,
    @Res() res: Response,
    @Headers('if-none-match') ifNoneMatch?: string,
  ): void {
    this.serve(req, res, ifNoneMatch);
  }

  private serve(req: RequestWithContext, res: Response, ifNoneMatch: string | undefined): void {
    const doc = this.holder?.current;
    const allowed =
      this.config.OPENAPI_PUBLIC ||
      (req.principal !== undefined && this.catalog.effectivePermissions(req.principal).has('system.openapi.read'));
    if (!allowed || !doc) throw new ProblemException('NOT_FOUND');
    res.setHeader('ETag', doc.etag);
    if (ifNoneMatch === doc.etag) {
      res.status(304).end();
      return;
    }
    res.status(200).type('application/json').send(doc.json);
  }
}
