import { Controller, Get, Param, Query, Req, Res, UseGuards, UseInterceptors } from '@nestjs/common';
import type { Request, Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import type { PaperFormat } from '../../common/ports/documents.port.js';
import type { SalesActor } from '../../common/ports/sales-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerModeGuard } from '../customer-mode.guard.js';
import { DocumentsService, type RenderKind } from './documents.service.js';
import { PdfRateLimitInterceptor } from './pdf-rate-limit.interceptor.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** 08 §2.8: PDF — исключение из правила `/orders*`: перепроверка по `ETag` (SHA-256 содержимого). */
const PDF_CACHE_CONTROL = 'private, no-cache';

function invalid(field: string, rule: string, message: string): never {
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

function single(q: Record<string, unknown>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined || v === '') return undefined;
  if (typeof v !== 'string') invalid(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

function orderId(raw: string): string {
  if (!UUID_RE.test(raw)) invalid('id', 'uuid', 'id — UUID.');
  return raw.toLowerCase();
}

/** `format` ∈ `a4` (по умолчанию) | `thermal80` — значения `print_jobs.paper` 07 (08 §4.8.5). */
function paperParam(q: Record<string, unknown>): PaperFormat {
  const v = single(q, 'format');
  if (v === undefined) return 'a4';
  if (v !== 'a4' && v !== 'thermal80') invalid('format', 'enum', 'format — a4 или thermal80.');
  return v;
}

function copyParam(q: Record<string, unknown>): boolean {
  const v = single(q, 'copy');
  if (v === undefined || v === 'false') return false;
  if (v === 'true') return true;
  return invalid('copy', 'type', 'copy — true или false.');
}

export function actorOf(req: RequestWithContext): SalesActor {
  const p = req.principal;
  if (!p) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
  return {
    userId: p.userId,
    roles: p.roles,
    isCustomer: p.kind === 'customer',
    sessionId: p.sessionId ?? null,
    deviceId: p.deviceId ?? null,
    requestId: req.id ?? null,
  };
}

/** `If-None-Match` содержит ETag (список через запятую, `*`, слабые `W/` сравниваются по значению). */
function etagMatches(header: string | string[] | undefined, etag: string): boolean {
  if (header === undefined) return false;
  const raw = Array.isArray(header) ? header.join(',') : header;
  return raw
    .split(',')
    .map((s) => s.trim().replace(/^W\//, ''))
    .some((s) => s === '*' || s === etag);
}

/**
 * Печатные формы заказа (RM-F-004, RM-F-012 п. 5; 08 §4.8.5; 11 §4.4): `invoice.pdf`, `receipt.pdf` — PDF backend
 * (право `order.documents.print`: `seller` — свои, `cashier`/`senior_seller`/`admin`/`owner`, `customer` — счёт своего
 * заказа); `waybill.pdf` — в R1 JSON-статус документа 1С (`order.read.*`, `customer` → 403). Чужой заказ → 404.
 * Ответ: `Content-Disposition: inline; filename="<kind>-<publicNumber>.pdf"`, `Cache-Control: private, no-cache`,
 * `ETag` = SHA-256 PDF → `304` по `If-None-Match`. Лимит — RL-PDF. Аудит не пишется; факт рендера — `print_jobs`.
 */
@Controller('orders')
@UseGuards(CustomerModeGuard)
@UseInterceptors(PdfRateLimitInterceptor)
export class DocumentsController {
  constructor(private readonly documents: DocumentsService) {}

  @Get(':id/documents/invoice.pdf')
  @RequirePermission('order.documents.print')
  async invoice(
    @Req() req: RequestWithContext & Request,
    @Param('id') id: string,
    @Query() q: Record<string, unknown>,
    @Res() res: Response,
  ): Promise<void> {
    await this.pdf('invoice', req, id, q, res);
  }

  @Get(':id/documents/receipt.pdf')
  @RequirePermission('order.documents.print')
  async receipt(
    @Req() req: RequestWithContext & Request,
    @Param('id') id: string,
    @Query() q: Record<string, unknown>,
    @Res() res: Response,
  ): Promise<void> {
    await this.pdf('receipt', req, id, q, res);
  }

  @Get(':id/documents/waybill.pdf')
  @RequireAnyPermission('order.read.own', 'order.read.all')
  async waybill(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ available: false; reason: string; onecNumber: string | null }> {
    const body = await this.documents.waybill(orderId(id), actorOf(req));
    res.setHeader('Cache-Control', PDF_CACHE_CONTROL);
    return body;
  }

  private async pdf(
    kind: RenderKind,
    req: RequestWithContext & Request,
    id: string,
    q: Record<string, unknown>,
    res: Response,
  ): Promise<void> {
    const oid = orderId(id);
    const paper = paperParam(q);
    const copy = copyParam(q);
    const doc = await this.documents.renderPdf({ kind, orderId: oid, paper, copy }, actorOf(req));
    const etag = `"${doc.sha256}"`;
    res.setHeader('Cache-Control', PDF_CACHE_CONTROL);
    res.setHeader('ETag', etag);
    if (etagMatches(req.headers['if-none-match'], etag)) {
      res.status(304).end();
      return;
    }
    res.status(200);
    res.setHeader('Content-Type', doc.contentType);
    res.setHeader('Content-Disposition', `inline; filename="${doc.fileName}"`);
    res.setHeader('Content-Length', String(doc.body.length));
    res.end(doc.body);
  }
}
