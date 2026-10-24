import { Module } from '@nestjs/common';
import { TransactionsController } from './transactions.controller.js';
import { TransactionQueryService } from './transactions.service.js';

/**
 * Модуль D-06 `transactions` (06 §7.4; 08 §4.14; 13 RM-G-004): **только чтение** журнала операций `transactions`
 * (писатель — `TransactionJournal` / порт `TRANSACTIONS_WRITER`, common/journal). Связанные документы читаются SQL по
 * ссылкам строки журнала, записи аудита — через `AUDIT_QUERY_PORT` (реализация — admin, RM-G-006).
 * Экспорт `TransactionQueryService` — для отчётов `admin.reports` (06 §7.4).
 */
@Module({
  controllers: [TransactionsController],
  providers: [TransactionQueryService],
  exports: [TransactionQueryService],
})
export class TransactionsModule {}
