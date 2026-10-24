import { Inject, Injectable } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { Money } from '../common/money/money.js';
import { SettingsReader } from '../common/settings/settings-reader.js';

/** Порог по умолчанию — 10 000 сом (ядро §20.2 п. 11; 10 RET-009; seed `0001_defaults.sql`). */
export const DEFAULT_RETURN_APPROVAL_THRESHOLD = '10000.00';

/**
 * Настройки заявок на возврат (ядро §21 п. 1; 10 RET-009, RET-012; 05 SYNC-050):
 * - `app_settings.returns_enabled` (по умолчанию `true`) — доступность функции пользователям (`false` — только по
 *   ответу Q-018 «возвраты полностью в 1С», без изменения кода);
 * - `app_settings.return_approval_threshold` (Money, по умолчанию 10 000 сом) — сверх порога отправку выполняет
 *   держатель `return.approve`;
 * - env `RETURNS_FROM_POS_ENABLED` (по умолчанию `false`) — **только** передача заявки в 1С через outbox.
 * Значения `app_settings` читаются через `SettingsReader` (кэш 10 с, изменение действует без перезапуска).
 */
@Injectable()
export class ReturnsSettings {
  constructor(
    private readonly settings: SettingsReader,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'RETURNS_FROM_POS_ENABLED'>,
  ) {}

  async enabled(): Promise<boolean> {
    const v = await this.settings.get('returns_enabled');
    if (typeof v === 'boolean') return v;
    if (v === 'false') return false;
    return true;
  }

  async threshold(): Promise<Money> {
    const v = await this.settings.get('return_approval_threshold');
    const raw =
      typeof v === 'string'
        ? v
        : typeof v === 'object' && v !== null && typeof (v as { amount?: unknown }).amount === 'string'
          ? (v as { amount: string }).amount
          : null;
    if (raw !== null && /^\d{1,12}(\.\d{1,2})?$/.test(raw.trim())) return Money.of(raw.trim());
    return Money.of(DEFAULT_RETURN_APPROVAL_THRESHOLD);
  }

  /** `RETURNS_FROM_POS_ENABLED`: заявка передаётся в 1С через outbox `return_request` (05 SYNC-050). */
  get outboxEnabled(): boolean {
    return this.config.RETURNS_FROM_POS_ENABLED;
  }
}
