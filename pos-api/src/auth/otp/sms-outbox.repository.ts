import { Inject, Injectable } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { smsOutbox } from '../../db/schema/index.js';
import type { SendOutcome, SmsTemplateKey } from '../../integrations/sms/sms-gateway.js';

export type SmsOutboxRow = typeof smsOutbox.$inferSelect;

/** `sms_outbox` (07 §5.61; 09 §6.9): журнал отправок без текста и кода. */
@Injectable()
export class SmsOutboxRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async insertQueued(
    input: {
      readonly phoneE164: string;
      readonly templateKey: SmsTemplateKey;
      readonly provider: 'smspro' | 'fake';
      readonly providerMessageId: string;
      readonly otpChallengeId: string;
      readonly requestId?: string | null;
      readonly at: Date;
    },
    ex: DbExecutor = this.db,
  ): Promise<SmsOutboxRow> {
    const rows = await ex
      .insert(smsOutbox)
      .values({
        phoneE164: input.phoneE164,
        templateKey: input.templateKey,
        provider: input.provider,
        providerMessageId: input.providerMessageId,
        status: 'queued',
        otpChallengeId: input.otpChallengeId,
        requestId: input.requestId?.slice(0, 200) ?? null,
        createdAt: input.at,
        updatedAt: input.at,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('sms_outbox.insert: INSERT не вернул строку');
    return row;
  }

  async findById(id: string, ex: DbExecutor = this.db): Promise<SmsOutboxRow | undefined> {
    const rows = await ex.select().from(smsOutbox).where(eq(smsOutbox.id, id)).limit(1);
    return rows[0];
  }

  async recordResult(
    id: string,
    r: {
      readonly status: 'sent' | 'failed';
      readonly outcome: SendOutcome;
      readonly providerStatus: number | null;
      readonly attempts: number;
      readonly smsParts: number;
      readonly phonesRecognized: number;
      readonly latencyMs: number;
      readonly at: Date;
    },
    ex: DbExecutor = this.db,
  ): Promise<void> {
    await ex
      .update(smsOutbox)
      .set({
        status: r.status,
        outcome: r.outcome,
        providerStatusCode: r.providerStatus,
        attempts: r.attempts,
        smsParts: r.smsParts,
        phonesRecognized: r.phonesRecognized,
        latencyMs: Math.max(0, Math.round(r.latencyMs)),
        sentAt: r.status === 'sent' ? r.at : null,
        error: r.status === 'failed' ? r.outcome : null,
        updatedAt: r.at,
      })
      .where(eq(smsOutbox.id, id));
  }
}
