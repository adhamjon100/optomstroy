/**
 * `common/journal` (06 §7.4 п. (г)): писатели журнальных таблиц, общие для модулей. `transactions` —
 * `TransactionJournal` (порт `TransactionsWriter`); `audit_logs` — `AuditService` (common/audit).
 */
export * from './transaction-journal.js';
