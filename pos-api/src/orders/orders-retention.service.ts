import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { DRIZZLE, type Database } from '../common/db/database.module.js';

/**
 * Срок хранения номера покупателя в заявке с планшета (07 §13.3 строка «`orders` — номер покупателя заявки с
 * планшета»; 11 PRIV-034; 10 KIOSK-023; P-002 §14.5): 90 дней после выдачи, закрытия или отмены, а у заявки, которую
 * никто не выдал и не отменил, — после создания.
 */
export const KIOSK_RECEIVER_PHONE_TTL_DAYS = 90;

/** Строк за один UPDATE (одна короткая транзакция на пачку; блокировки строк не держатся долго). */
const MASK_BATCH = 500;
/** Предохранитель: не больше пачек за один запуск (остаток — следующие сутки). */
const MAX_BATCHES = 200;

/**
 * Обработчик модуля `orders` в задаче сроков хранения `retention.daily` (06 §7.5, MOD-024; 07 §13.3 «Планшет
 * магазина (ADR-115; задача TAB-1-10)»; 11 PRIV-034, PRIV-016): маскирование номера покупателя в заявках с планшета
 * (`created_via='kiosk'`) **одним UPDATE** на пачку — `receiver_phone_e164` → NULL, маска `+996 7** *** *01` (формат
 * `PhoneMasked`, как `maskPhone` журнала) → `receiver_phone_masked` (CHECK `orders_receiver_phone_masked_chk` и
 * `orders_receiver_phone_masked_null_chk`; CHECK E.164 `orders_receiver_phone_e164_chk` не ослабляется). Срок —
 * `coalesce(shipped_at, closed_at, cancelled_at, created_at) < now() − 90 дней`; повторный запуск строку не меняет
 * (условие `receiver_phone_e164 IS NOT NULL`); строки, занятые другой транзакцией, пропускаются (`FOR UPDATE SKIP
 * LOCKED`) и маскируются следующим запуском. Номер в заказе 1С и копии номера в `onec_outbox.payload`,
 * `otp_challenges`, `sms_outbox` задание не трогает (Q-339; known_issues R-KI-01). Исполнение журналируется событием
 * аудита `retention.executed` (таблица, столбец, число строк) — без номеров.
 *
 * Регистрации в pg-boss у сервиса нет: его вызывает единственный обработчик очереди `retention.daily`
 * (`ReturnsJobsBridge`), второй `boss.work` на ту же очередь не заводится.
 */
@Injectable()
export class OrdersRetentionService {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly audit: AuditService,
  ) {}

  async maskKioskReceiverPhones(): Promise<{ masked: number }> {
    let masked = 0;
    for (let batch = 0; batch < MAX_BATCHES; batch++) {
      const n = await this.maskBatch();
      masked += n;
      if (n < MASK_BATCH) break;
    }
    return { masked };
  }

  private async maskBatch(): Promise<number> {
    return this.db.transaction(async (tx) => {
      const ctx = systemActor('retention');
      await applyAuditGucs(tx, ctx);
      const r = await tx.execute<{ id: string }>(sql`
        WITH due AS (
          SELECT id FROM orders
           WHERE created_via = 'kiosk' AND receiver_phone_e164 IS NOT NULL
             AND coalesce(shipped_at, closed_at, cancelled_at, created_at)
                 < now() - make_interval(days => ${KIOSK_RECEIVER_PHONE_TTL_DAYS})
           ORDER BY created_at
           LIMIT ${MASK_BATCH}
           FOR UPDATE SKIP LOCKED)
        UPDATE orders o
           SET receiver_phone_masked =
                 '+996 ' || substr(o.receiver_phone_e164, 5, 1) || '** *** *' || right(o.receiver_phone_e164, 2),
               receiver_phone_e164 = NULL,
               row_version = o.row_version + 1,
               updated_at = now()
          FROM due
         WHERE o.id = due.id
        RETURNING o.id`);
      const rows = r.rows.length;
      if (rows === 0) return 0;
      // Аудит — последним оператором транзакции (07 §9.3); без номеров и идентификаторов заказов.
      await this.audit.write(
        ctx,
        {
          action: 'retention.executed',
          entityType: 'orders',
          after: {
            table: 'orders',
            column: 'receiver_phone_e164',
            createdVia: 'kiosk',
            olderThanDays: KIOSK_RECEIVER_PHONE_TTL_DAYS,
            rows,
          },
        },
        tx,
      );
      return rows;
    });
  }
}
