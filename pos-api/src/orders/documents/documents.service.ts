import { Inject, Injectable, Logger } from '@nestjs/common';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import type {
  DocumentsPort,
  OrderDocumentsAvailability,
  PaperFormat,
  RenderedDocument,
} from '../../common/ports/documents.port.js';
import type { SalesActor } from '../../common/ports/sales-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import {
  type DocumentModel,
  invoiceModel,
  type OrderDocRow,
  receiptModel,
  type SellerRequisites,
} from './document-model.js';
import { DOCUMENT_ASSETS, type DocumentAssets } from './documents-assets.js';
import { type DocumentViewer, DocumentsRepository } from './documents.repository.js';
import { PdfRenderer } from './pdf/pdf-renderer.js';
import { PdfTemplateStore } from './pdf/pdf-template.js';

/**
 * Печатные документы заказа (RM-F-004, RM-F-012 п. 5; 08 §4.8.5, §7.3; 10 PRINT-001…PRINT-010; ядро §19.4):
 * - счёт на оплату (`invoice`) — после создания заказа, как только у заказа есть номер «Заказа клиента» 1С
 *   (PRINT-003, Q-024): без номера (`submitting`, `submit_failed`) → `409 ORDER_STATE_INVALID`;
 * - нефискальный товарный чек (`receipt`) — только после получения оплаты (платёж `received`, PRINT-005);
 * - накладная (`waybill`) — печатная форма 1С, в R1 `available:false` (PRINT-004, D-27).
 * Печать не блокирует создание заказа (PRINT-001): PDF формируется по запросу, ошибка рендера → `500 INTERNAL`
 * только для этого запроса и строка `print_jobs` со статусом `failed`. Реализует `DocumentsPort` (common/ports).
 */
export type RenderKind = 'invoice' | 'receipt';

export const ORGANIZATION_SETTING_KEY = 'print.organization';
/** Реквизиты по умолчанию, пока администратор не заполнил `app_settings.print.organization` (Q-019). */
export const DEFAULT_SELLER: SellerRequisites = { name: 'Оптомстрой' };

/** Статусы, в которых счёт не выдаётся даже при наличии номера 1С. */
const INVOICE_BLOCKED_STATUSES = new Set(['draft', 'submitting', 'submit_failed', 'cancelled']);

export interface RenderedPdf extends RenderedDocument {
  readonly sha256: string;
  readonly orderVersion: number; // money-double: allow — версия заказа (row_version), не деньги
  readonly pageWidth: number; // money-double: allow — геометрия PDF в пунктах, не деньги
}

export interface RenderRequest {
  readonly kind: RenderKind;
  readonly orderId: string;
  readonly paper: PaperFormat;
  readonly copy: boolean;
}

function str(v: unknown): string | undefined {
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : undefined;
}

@Injectable()
export class DocumentsService implements DocumentsPort {
  private readonly logger = new Logger('documents');
  private readonly templates: PdfTemplateStore;
  private readonly renderer: PdfRenderer;

  constructor(
    private readonly repo: DocumentsRepository,
    private readonly settings: SettingsReader,
    private readonly catalog: PermissionCatalog,
    @Inject(DOCUMENT_ASSETS) assets: DocumentAssets,
  ) {
    this.templates = new PdfTemplateStore(assets.templatesDir);
    this.renderer = new PdfRenderer({ regular: assets.fontRegular, bold: assets.fontBold });
  }

  // ------------------------------------------------------------------------------------------ DocumentsPort

  async availability(orderId: string, actor: SalesActor): Promise<OrderDocumentsAvailability> {
    const state = await this.repo.orderState(orderId);
    const waybill = { available: false, reason: 'waybill_from_onec' } as const;
    if (!state) return { invoice: null, receipt: null, waybill };
    const perms = this.permissions(actor);
    const canPrint = actor.userId === null || perms.has('order.documents.print');
    const base = `/api/v1/orders/${orderId}/documents`;
    const invoiceOk = canPrint && state.onecNumber !== null && !INVOICE_BLOCKED_STATUSES.has(state.status);
    const receiptOk = canPrint && !actor.isCustomer && (await this.repo.hasReceivedPayment(orderId));
    return {
      invoice: invoiceOk ? `${base}/invoice.pdf` : null,
      receipt: receiptOk ? `${base}/receipt.pdf` : null,
      waybill,
    };
  }

  async render(kind: RenderKind, orderId: string, paper: PaperFormat, actor: SalesActor): Promise<RenderedDocument> {
    const r = await this.renderPdf({ kind, orderId, paper, copy: false }, actor);
    return { contentType: r.contentType, fileName: r.fileName, body: r.body };
  }

  // ------------------------------------------------------------------------------------------ HTTP

  /** Рендер для `GET /orders/{id}/documents/{kind}.pdf` с записью факта в `print_jobs`. */
  async renderPdf(req: RenderRequest, actor: SalesActor): Promise<RenderedPdf> {
    if (req.kind === 'receipt' && actor.isCustomer) {
      // 08 §4.8.5: customer — только счёт своего заказа (receipt → 403).
      throw new ProblemException('FORBIDDEN', { detail: 'Товарный чек доступен только сотрудникам.' });
    }
    const order = await this.repo.findOrder(req.orderId, this.viewer(actor));
    if (!order) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    const model = await this.buildModel(req, order);
    const version = Math.min(Math.max(order.rowVersion, 1), 32767);
    try {
      const t = this.templates.get(req.kind, req.paper);
      const started = Date.now();
      const pdf = await this.renderer.render(t, model, {
        creationDate: order.createdAt,
        title: `${t.title} ${String(model.number)}`,
      });
      this.logger.log({
        event: 'documents.rendered',
        kind: req.kind,
        paper: req.paper,
        orderId: order.id,
        pages: pdf.pages,
        ms: Date.now() - started,
      });
      if (actor.userId !== null) {
        await this.repo.recordPrintJob({
          orderId: order.id,
          kind: req.kind,
          paper: req.paper,
          version,
          userId: actor.userId,
          sha256Hex: pdf.sha256,
          error: null,
        });
      }
      return {
        contentType: 'application/pdf',
        fileName: `${req.kind}-${order.publicNumber}.pdf`,
        body: pdf.bytes,
        sha256: pdf.sha256,
        orderVersion: version,
        pageWidth: pdf.pageWidth,
      };
    } catch (e) {
      if (e instanceof ProblemException) throw e;
      const message = e instanceof Error ? e.message : String(e);
      this.logger.error({ event: 'documents.render_failed', kind: req.kind, orderId: order.id, error: message });
      if (actor.userId !== null) {
        await this.repo
          .recordPrintJob({
            orderId: order.id,
            kind: req.kind,
            paper: req.paper,
            version,
            userId: actor.userId,
            sha256Hex: null,
            error: message.slice(0, 500),
          })
          .catch(() => undefined);
      }
      throw new ProblemException('INTERNAL', { detail: 'Не удалось сформировать документ. Повторите позже.' });
    }
  }

  /** Накладная в R1 — статус документа 1С вместо PDF (08 §4.8.5, PRINT-004; D-27). */
  async waybill(
    orderId: string,
    actor: SalesActor,
  ): Promise<{ available: false; reason: string; onecNumber: string | null }> {
    if (actor.isCustomer) throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    const order = await this.repo.findOrder(orderId, this.viewer(actor));
    if (!order) throw new ProblemException('NOT_FOUND', { detail: 'Заказ не найден.' });
    return { available: false, reason: 'waybill_from_onec', onecNumber: order.onecNumber };
  }

  // ------------------------------------------------------------------------------------------ внутреннее

  private async buildModel(req: RenderRequest, order: OrderDocRow): Promise<DocumentModel> {
    if (req.kind === 'invoice') {
      if (order.onecNumber === null || INVOICE_BLOCKED_STATUSES.has(order.status)) {
        throw new ProblemException('ORDER_STATE_INVALID', {
          detail:
            order.status === 'cancelled'
              ? 'Заказ отменён: счёт не выдаётся.'
              : 'Счёт будет доступен после получения номера заказа 1С («Ожидает номер 1С»).',
          resource: 'order',
          reason: order.status === 'cancelled' ? 'order_cancelled' : 'onec_number_pending',
          currentStatus: order.status,
        });
      }
      const items = await this.repo.items(order.id);
      return invoiceModel(order, await this.seller(), items, req.copy);
    }
    const payments = await this.repo.receivedPayments(order.id);
    if (payments.length === 0) {
      throw new ProblemException('ORDER_STATE_INVALID', {
        detail: 'Товарный чек печатается только после получения оплаты.',
        resource: 'order',
        reason: 'payment_not_received',
        currentStatus: order.status,
      });
    }
    const items = await this.repo.items(order.id);
    return receiptModel(order, await this.seller(), items, payments, req.copy);
  }

  /** Реквизиты продавца из `app_settings.print.organization` (json; Q-019), иначе — значения по умолчанию. */
  private async seller(): Promise<SellerRequisites> {
    const v = await this.settings.get(ORGANIZATION_SETTING_KEY);
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return DEFAULT_SELLER;
    const o = v as Record<string, unknown>;
    const pick = (k: string): Record<string, string> => {
      const s = str(o[k]);
      return s === undefined ? {} : { [k]: s };
    };
    return {
      name: str(o.name) ?? DEFAULT_SELLER.name,
      ...pick('inn'),
      ...pick('address'),
      ...pick('phone'),
      ...pick('bankName'),
      ...pick('bic'),
      ...pick('account'),
    };
  }

  private permissions(actor: SalesActor): ReadonlySet<string> {
    return this.catalog.effectivePermissions({ roles: actor.roles, status: 'active' });
  }

  private viewer(actor: SalesActor): DocumentViewer {
    return {
      userId: actor.userId,
      readAll: actor.userId === null || this.permissions(actor).has('order.read.all'),
      isCustomer: actor.isCustomer,
    };
  }
}
