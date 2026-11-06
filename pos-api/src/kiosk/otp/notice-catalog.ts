/**
 * Каталог версий текста информирования перед кодом заявки с планшета магазина (11 PRIV-032; 10 KIOSK-022; 08 §4.25.1;
 * P-002 §8.5 п. 2, §14.4; ADR-115 п. 16). Источник — `contracts/legal/notices_ru.md`, раздел `kiosk_order_notice`:
 * это информирование, а не согласие, поэтому каталог отдельный от `CONSENT_CATALOG` и записей `consents` нет.
 * Каталог скомпилирован в код (образ pos-api не содержит `contracts/`); совпадение версий и SHA-256 с файлом проверяет
 * `test/kiosk/notice-catalog.spec.ts`.
 *
 * Новая версия текста (любое заполнение метки `[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: …]`, любая правка юриста — Q-348): новый
 * раздел файла, новая запись `versions` и смена `current`; прежние версии остаются — коды и заявки хранят свою версию
 * (`otp_challenges.notice_version`, `orders.pd_notice_version`) и хэш показанного текста (`orders.pd_notice_sha256`).
 */
export interface NoticeTextVersion {
  /** `YYYY-MM-DD` — значение `noticeVersion` в `POST /kiosk/order-otp`. */
  readonly version: string;
  /** SHA-256 (hex, нижний регистр) текста блока `text` раздела — для `orders.pd_notice_sha256`. */
  readonly sha256: string;
}

export interface NoticeEntry {
  /** Код раздела `notices_ru.md` (`## <код> — версия <YYYY-MM-DD>`). */
  readonly code: string;
  /** Версия, которую показывает текущая сборка приложения (02 §7 `kiosk_notice_short`, `kiosk_notice_full`). */
  readonly current: string;
  readonly versions: readonly NoticeTextVersion[];
}

/** Код раздела текста перед запросом кода на планшете (SCR-52, шаг «Телефон»). */
export const KIOSK_ORDER_NOTICE_CODE = 'kiosk_order_notice';

export const NOTICE_CATALOG: Readonly<Record<typeof KIOSK_ORDER_NOTICE_CODE, NoticeEntry>> = Object.freeze({
  kiosk_order_notice: {
    code: KIOSK_ORDER_NOTICE_CODE,
    current: '2026-11-04',
    versions: [{ version: '2026-11-04', sha256: '7ac18a5d3905144afc88b8a9140a25eb5b74125be528b19208d4bbfe6c629af8' }],
  },
});

/**
 * Версия текста `kiosk_order_notice` или `undefined` (неизвестная версия → `422 VALIDATION_FAILED`, rule
 * `notice_version`, до отправки SMS). Принимаются все версии каталога, а не только `current`: приложение старой сборки
 * передаёт показанную им версию, и она остаётся доказуемой.
 */
export function kioskNoticeVersion(version: unknown): NoticeTextVersion | undefined {
  if (typeof version !== 'string') return undefined;
  return NOTICE_CATALOG.kiosk_order_notice.versions.find((v) => v.version === version);
}

/** SHA-256 текста версии (hex) для `orders.pd_notice_sha256` (WP-S4C) или `undefined`, если версии нет. */
export function kioskNoticeSha256(version: string): string | undefined {
  return kioskNoticeVersion(version)?.sha256;
}
