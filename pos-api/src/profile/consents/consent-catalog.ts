import type { ConsentKind } from '../../common/enums.js';

/**
 * Каталог версий текстов согласий (07 §5.14, DATA-113; 11 §10.3; 13 RM-D-004 «версия текста из
 * contracts/legal/consents_ru.md»). `sha256` — хэш показанного текста (`consents.text_sha256`); совпадение с файлом
 * contracts/legal/consents_ru.md проверяет test/profile/consent-catalog.profile-spec.ts. Новая версия текста — новая
 * запись в `versions` и смена `current` (прежние версии остаются для доказуемости ранее выданных согласий).
 *
 * `face_scan` — R2 (Q-003): в каталоге нет → любой запрос с этим видом отвергается (VALIDATION_FAILED).
 */
export interface ConsentTextVersion {
  readonly version: string;
  readonly sha256: string;
}

export interface ConsentKindEntry {
  readonly kind: ConsentKind;
  readonly current: string;
  readonly versions: readonly ConsentTextVersion[];
  /** Согласие привязано к устройству (`consents.device_id`): только `biometrics_device` (07 §5.14). */
  readonly perDevice: boolean;
  /** Обязательная запись для всех пользователей (`GET /me/consents` → `required[]`; 09 §7.1). */
  readonly mandatory: boolean;
}

export const CONSENT_CATALOG: Readonly<Partial<Record<ConsentKind, ConsentKindEntry>>> = Object.freeze({
  personal_data: {
    kind: 'personal_data',
    current: '2026-10-01',
    versions: [{ version: '2026-10-01', sha256: '694422aa0afe21bb1d9f237607d80feb66ae34e406a298fb942cafc909ecdaff' }],
    perDevice: false,
    mandatory: true,
  },
  activity_sphere: {
    kind: 'activity_sphere',
    current: '2026-10-01',
    versions: [{ version: '2026-10-01', sha256: '6f3d12af9ce83662f520ff51e210861da25f54081bab4716cc492ad782882f39' }],
    perDevice: false,
    mandatory: false,
  },
  biometrics_device: {
    kind: 'biometrics_device',
    current: '2026-10-01',
    versions: [{ version: '2026-10-01', sha256: 'e28ca2cdd8d71b95af7f06757366e14af0986209768f202b3927f2ae55dcfe48' }],
    perDevice: true,
    mandatory: false,
  },
  sms: {
    kind: 'sms',
    current: '2026-10-01',
    versions: [{ version: '2026-10-01', sha256: '1ad4acef18c36844d4f97dd3e82268242a2869f7bf215345e1b0f771a0f1b83f' }],
    perDevice: false,
    mandatory: false,
  },
});

export function consentEntry(kind: string): ConsentKindEntry | undefined {
  return Object.prototype.hasOwnProperty.call(CONSENT_CATALOG, kind) ? CONSENT_CATALOG[kind as ConsentKind] : undefined;
}

/** Хэш текста версии или `undefined` (неизвестный вид/версия). */
export function consentTextHash(kind: string, version: string): Buffer | undefined {
  const v = consentEntry(kind)?.versions.find((x) => x.version === version);
  return v ? Buffer.from(v.sha256, 'hex') : undefined;
}

export function isCurrentConsentVersion(kind: string, version: string): boolean {
  return consentEntry(kind)?.current === version;
}

export function mandatoryConsentKinds(): ConsentKindEntry[] {
  return Object.values(CONSENT_CATALOG).filter((e): e is ConsentKindEntry => e?.mandatory === true);
}
