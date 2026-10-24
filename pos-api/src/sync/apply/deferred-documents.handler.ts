import type { Logger } from 'pino';
import type { SyncEntity } from '../../common/enums.js';
import type { ApplyScope, ChangeItemHandler } from './apply.types.js';

/** Платёжные документы 1С, применение которых ждёт решения заказчика Q-012 (ТЗ для 1С 5.1, вопрос 57). */
export const DEFERRED_PAYMENT_DOC_TYPES = [
  'Document_ПриходныйКассовыйОрдер',
  'Document_ПоступлениеБезналичныхДенежныхСредств',
] as const;

/**
 * ПКО и поступления безналичных из `/changes` (05 §6.2 состав; Q-012; разбор расхождений пп. 8, 31): в R1
 * платежи POS передаются в 1С через outbox и подтверждаются его ответом, а документы, введённые в 1С без POS,
 * в журнале операций не показываются, пока заказчик не решит Q-012. Элементы пропускаются **осознанно**: счётчик
 * `deferred` цикла и запись в журнал; данные POS не меняются. После подключения применения (ответ по Q-012) —
 * разовая перерегистрация состава `npm run onec:reregister` (05 §6.2 уточнение п. 3, 16 §10), чтобы снятые ack
 * регистрации пришли снова.
 */
export class DeferredDocumentsHandler implements ChangeItemHandler {
  readonly types: readonly string[] = DEFERRED_PAYMENT_DOC_TYPES;
  readonly deferred = true;

  constructor(private readonly log?: Pick<Logger, 'info'>) {}

  entityOf(): SyncEntity | undefined {
    return undefined;
  }

  apply(_scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void> {
    const byType: Record<string, number> = {};
    for (const it of items) {
      const t = String(it.type === 'ObjectDeletion' ? it.objectType : it.type);
      byType[t] = (byType[t] ?? 0) + 1;
    }
    this.log?.info(
      { deferred: items.length, byType },
      'onec.changes.deferred: платёжные документы 1С не применяются до решения Q-012 (после — onec:reregister)',
    );
    return Promise.resolve();
  }
}
