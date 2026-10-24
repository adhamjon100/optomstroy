import type { SalesActor } from './sales-context.js';

/**
 * `DocumentsPort` — печатные документы заказа (RM-F-004; D-26, D-27; 10 PRINT-; ядро §19.4): счёт — после создания
 * заказа, нефискальный товарный чек — после получения оплаты, накладная — из 1С (по умолчанию `available:false`).
 * Реализация — агент F-be-docs-notif (`src/orders/documents/**`, PDF — pdfkit + шрифт Inter из `assets/fonts`);
 * потребитель — F-be-orders (`Order.documents` в `GET /orders/{id}`).
 */
export const DOCUMENTS_PORT = 'sales.DocumentsPort' as const;

export type OrderDocumentKind = 'invoice' | 'receipt' | 'waybill';
export type PaperFormat = 'a4' | 'thermal80';

export interface OrderDocumentsAvailability {
  /** URL `…/documents/invoice.pdf` или `null`. */
  readonly invoice: string | null;
  /** URL `…/documents/receipt.pdf` (только после получения оплаты) или `null`. */
  readonly receipt: string | null;
  readonly waybill: { readonly available: boolean; readonly reason?: string };
}

export interface RenderedDocument {
  readonly contentType: 'application/pdf';
  readonly fileName: string;
  readonly body: Buffer;
}

export interface DocumentsPort {
  availability(orderId: string, actor: SalesActor): Promise<OrderDocumentsAvailability>;
  render(
    kind: Exclude<OrderDocumentKind, 'waybill'>,
    orderId: string,
    paper: PaperFormat,
    actor: SalesActor,
  ): Promise<RenderedDocument>;
}
