import { SetMetadata } from '@nestjs/common';
import type { RequestWithContext } from '../http/request-context.js';

export const IDEMPOTENT = 'optomstroy:idempotent';
export const IDEMPOTENCY_KEY_HEADER = 'Idempotency-Key';
export const IDEMPOTENT_REPLAYED_HEADER = 'Idempotent-Replayed';

export interface IdempotentOptions {
  /** Ключ обязателен (перечень 08 §2.7 «Где обязателен»); иначе — «допускается». */
  readonly required: boolean;
  /**
   * Субъект скоупа для публичных маршрутов без `principal` (например, `reg:<sha256(jti)>` для
   * `POST /registration/complete`, B-AR-01). По умолчанию — `user:<principal.userId>`.
   */
  readonly subject?: (req: RequestWithContext) => { subjectKey: string; userId: string | null } | undefined;
  /**
   * Условие обязательности по запросу (например, `PUT /cart/items/{variantId}` только при `mode=increment`).
   */
  readonly requiredWhen?: (req: RequestWithContext) => boolean;
}

/**
 * Маршрут участвует в идемпотентности 08 §2.7. Для мутаций без декоратора заголовок `Idempotency-Key`
 * тоже обрабатывается («допускается» на любом POST/PUT/PATCH), но не обязателен.
 */
export const Idempotent = (options: IdempotentOptions = { required: true }): MethodDecorator =>
  SetMetadata(IDEMPOTENT, options);
