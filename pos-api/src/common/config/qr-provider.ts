/**
 * Значение env `QR_PROVIDER` и коды хранения/контрактов (ADR-123, P-004).
 *
 * - env (после разбора `env.schema.ts`): `onec | none | bank`; `bakai` — устаревший синоним `bank`, приводится к нему;
 * - код хранения и контрактов: `payments.qr_provider` (07), `QrProviderMode` / `QrInfo.provider` (08, OpenAPI),
 *   `contracts/enums.json` — `onec | none | bakai`. Код `bakai` — исторический код «прямой API банка» **независимо от
 *   банка** (банк заказчика — не Бакай, `[НЕ ПОДТВЕРЖДЕНО: Q-381]`); миграции и новой версии контрактов нет.
 */
export type QrProviderEnv = 'onec' | 'none' | 'bank';
export type QrProviderCode = 'onec' | 'none' | 'bakai';

/** env `QR_PROVIDER` → код хранения/контракта (`bank` → `bakai`). */
export function qrProviderCode(mode: QrProviderEnv): QrProviderCode {
  return mode === 'bank' ? 'bakai' : mode;
}
