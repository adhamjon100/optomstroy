import { Inject, Injectable } from '@nestjs/common';
import type { KioskCustomerMatch } from '../../common/enums.js';
import { isPhoneVerified } from '../links/customer-link.presenter.js';
import {
  type CardLinkFacts,
  type CustomerCardRow,
  CustomerLinksRepository,
} from '../links/customer-links.repository.js';
import {
  CUSTOMER_MATCHING,
  type CustomerMatching,
  KG_E164,
  type MatchCandidate,
  type OnecLookupState,
} from './customer-matching.port.js';

/** Почему итог не `single` (для журнала и аудита заявки; без ПДн). `matched` — итог `single`. */
export type KioskMatchReason =
  | 'matched'
  | 'no_cards'
  | 'several_cards'
  | 'card_missing'
  | 'legal_entity'
  | 'not_primary_phone'
  | 'phone_not_verified'
  | 'duplicate'
  | 'link_conflict'
  | 'linked_to_other_phone';

/** Итог классификации P-002 §8.6 (`orders.kiosk_customer_match`, в DTO для персонала — `kioskCustomerMatch`). */
export interface KioskMatchDecision {
  /** Клиент заявки: карточка при `single`; иначе `null` — «Розничный покупатель» (ORD-004), номер — в получателе. */
  readonly customerId: string | null;
  readonly match: KioskCustomerMatch;
  readonly reason: KioskMatchReason;
}

export interface KioskCustomerMatchResult extends KioskMatchDecision {
  /** Обращение к 1С: `unavailable` — решение по реплике (таймаут или ошибка); `disabled` — порт 1С не подключён. */
  readonly onec: OnecLookupState;
}

export interface KioskMatchInput {
  /** Номер из кода `kiosk_order`, E.164. */
  readonly phoneE164: string;
  /** Кандидаты `CustomerMatching.findByPhone` (без повторов). */
  readonly candidates: readonly MatchCandidate[];
  /**
   * Текущий снимок карточки единственного кандидата и её привязки. Не задан (карточка удалена между поиском и
   * чтением) — отказ по умолчанию: `ambiguous`.
   */
  readonly card?: { readonly row: CustomerCardRow; readonly links: CardLinkFacts };
}

function decision(match: KioskCustomerMatch, reason: KioskMatchReason, customerId: string | null = null) {
  return { customerId, match, reason } satisfies KioskMatchDecision;
}

/**
 * Классификатор таблицы P-002 §8.6 без ввода-вывода (10 KIOSK-014, AC-KIOSK-014; 05 ONEC-110; 11 SEC-130
 * «Планшет магазина»; ADR-115 п. 4):
 * - карточек нет → `none`, клиент заявки — «Розничный покупатель» (ORD-004; Р-02 (а), Р-03 (а));
 * - карточек несколько → `ambiguous`, «Розничный покупатель»;
 * - одна карточка → `single` (заявка на эту карточку) только при всех условиях SEC-130: карточка не юрлица
 *   (Р-04 (а)); номер — **основной** телефон карточки, полученной из 1С полной синхронизацией (`isPhoneVerified`,
 *   Р-23 (а); Q-315 остаётся открытым); нет признака дубля (`onec_status = duplicate`); нет открытой привязки
 *   `conflict`; нет `confirmed`-привязки к пользователю с **другим** телефоном (иначе чужой человек увидел бы заявку
 *   и номер в «Мои заказы» — P-002 §8.6). Любое условие не выполнено → `ambiguous`, «Розничный покупатель».
 *
 * Правило реплики (Q-347): кандидат, известный только из живого поиска 1С, лежит в реплике строкой `legal` без
 * `synced_at` (`PgCustomerMatching.ensureReplicaRow`) и потому `single` не даёт. Порядок проверок влияет только на
 * `reason`, итог от него не зависит.
 */
export function classifyKioskMatch(input: KioskMatchInput): KioskMatchDecision {
  const { phoneE164: phone, candidates } = input;
  if (candidates.length === 0) return decision('none', 'no_cards');
  if (candidates.length > 1) return decision('ambiguous', 'several_cards');
  const candidate = candidates[0];
  const card = input.card;
  if (!card || card.row.id !== candidate.customerId) return decision('ambiguous', 'card_missing');
  const { row, links } = card;
  if (row.customerType === 'legal') return decision('ambiguous', 'legal_entity');
  // Второй контакт (`secondary`), карточка только из ответа 1С (`onec`) или основной контакт `customer_contacts`,
  // отличный от `primary_phone_e164`, — номер не основной.
  if (candidate.matchKind !== 'primary' || row.primaryPhoneE164 !== phone) {
    return decision('ambiguous', 'not_primary_phone');
  }
  // Р-23 (а): основной телефон карточки из полной синхронизации 1С (source = onec, onec_ref и synced_at заданы).
  if (!isPhoneVerified(row, phone)) return decision('ambiguous', 'phone_not_verified');
  if (row.onecStatus === 'duplicate') return decision('ambiguous', 'duplicate');
  if (links.hasOpenConflict) return decision('ambiguous', 'link_conflict');
  if (links.confirmedUserPhones.some((p) => p !== phone)) return decision('ambiguous', 'linked_to_other_phone');
  return decision('single', 'matched', row.id);
}

export interface KioskMatchOptions {
  /** `X-Request-Id` для вызова 1С. */
  readonly requestId?: string;
}

/**
 * Поиск клиента заявки с планшета магазина (TAB-1-13; шаг 2 `POST /kiosk/orders` — P-002 §8.5 п. 3, §8.6; 09 §7.8
 * точка (в)). Экспорт `CustomerMatchingModule`.
 *
 * Когда: после верного кода `kiosk_order` и **вне** транзакции создания заявки, поэтому исполнитель транзакции не
 * принимается. Источники — `CustomerMatching.findByPhone`: реплика плюс синхронный `GET /pos/v1/customers?phone=` с
 * таймаутом `ONEC_SYNC_CHECK_TIMEOUT_MS`; 1С не ответила (`onec = unavailable`) — решение по реплике. Итог —
 * `classifyKioskMatch`; планшету он не показывается (KIOSK-014).
 *
 * Записи: сам поиск ничего не пишет — ни `customer_links`, ни задачу `customer/create` (`POST /pos/v1/customers`), ни
 * `users`, ни карточку 1С (Р-02 (а)). Единственная запись — прежнее поведение `findByPhone`: строка-заглушка реплики
 * `customers` (`source = onec`, `customer_type = legal`, `synced_at` NULL, `INSERT … ON CONFLICT DO NOTHING`) для
 * карточки 1С, которой реплика не знает. Без транзакции вызывающего она фиксируется сразу и остаётся, даже если заявка
 * потом не создастся; полную карточку запишет синхронизация `customers` (07 §5.28). Телефон в журналы не пишется
 * (11 SEC-062, AC-ONEC-088).
 */
@Injectable()
export class KioskCustomerMatcher {
  constructor(
    @Inject(CUSTOMER_MATCHING) private readonly matching: CustomerMatching,
    private readonly links: CustomerLinksRepository,
  ) {}

  /** Номер — E.164 `+996XXXXXXXXX` из кода `kiosk_order`; иной формат → `RangeError` (без обращения к 1С). */
  async matchKioskCustomer(phoneE164: string, options: KioskMatchOptions = {}): Promise<KioskCustomerMatchResult> {
    if (!KG_E164.test(phoneE164)) throw new RangeError('KioskCustomerMatcher: телефон — E.164 +996XXXXXXXXX');
    const found = await this.matching.findByPhone(phoneE164, options.requestId ? { requestId: options.requestId } : {});
    let card: KioskMatchInput['card'];
    if (found.candidates.length === 1) {
      const row = await this.links.findCard(found.candidates[0].customerId);
      if (row) card = { row, links: await this.links.linkFactsForCard(row.id) };
    }
    const result = classifyKioskMatch({ phoneE164, candidates: found.candidates, ...(card ? { card } : {}) });
    return { ...result, onec: found.onec };
  }
}
