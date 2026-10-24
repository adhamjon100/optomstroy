import { Module } from '@nestjs/common';
import { DOCUMENTS_PORT } from '../../common/ports/documents.port.js';
import { bindSalesPort } from '../../sales-domain/sales-ports.module.js';
import { DOCUMENT_ASSETS, defaultDocumentAssets } from './documents-assets.js';
import { DocumentsController } from './documents.controller.js';
import { DocumentsRepository } from './documents.repository.js';
import { DocumentsService } from './documents.service.js';
import { PdfRateLimitInterceptor, RL_PDF_LIMIT, RL_PDF_PER_MINUTE } from './pdf-rate-limit.interceptor.js';

/**
 * Печатные документы заказа (RM-F-004, RM-F-012 п. 5; 06 §7.4 — часть модуля `orders`: `/orders/{id}/documents/
 * {invoice|receipt|waybill}.pdf`). `PdfRenderer` на pdfkit (шрифт Inter с кириллицей — `pos-api/assets/fonts`, OFL),
 * шаблоны — `pos-api/assets/templates/pdf/*.json` (замена без изменения кода, Q-019). Реализация `DocumentsPort`
 * привязана `bindSalesPort(DOCUMENTS_PORT, DocumentsService)` — модуль orders получает её по токену (без импорта).
 * Отдельный Nest-модуль (подключён в AppModule рядом с OrdersModule) — orders и документы развиваются независимо.
 */
@Module({
  controllers: [DocumentsController],
  providers: [
    DocumentsRepository,
    { provide: DOCUMENT_ASSETS, useFactory: defaultDocumentAssets },
    { provide: RL_PDF_LIMIT, useValue: RL_PDF_PER_MINUTE },
    PdfRateLimitInterceptor,
    ...bindSalesPort(DOCUMENTS_PORT, DocumentsService),
  ],
  exports: [DocumentsService],
})
export class DocumentsModule {}
