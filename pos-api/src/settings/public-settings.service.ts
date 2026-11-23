import { createHash } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { AppVersionPolicy } from '../common/app-version/app-version.policy.js';
import { formatVersionHeader } from '../common/app-version/version-policy.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { qrProviderCode } from '../common/config/qr-provider.js';
import { SettingsReader } from '../common/settings/settings-reader.js';
import { kioskIntegerSetting } from './public-settings.map.js';

export type QrProviderMode = 'none' | 'onec' | 'bakai';
export type CustomerStockDisplay = 'status' | 'quantity';

export interface DeliverySlot {
  readonly from: string;
  readonly to: string;
}

export interface SupportContact {
  readonly kind: 'phone' | 'telegram' | 'email';
  readonly value: string;
  readonly label?: string;
}

/** `PublicSettings` (08 §4.23.1; contracts/openapi `PublicSettings`). */
export interface PublicSettings {
  readonly deliverySlots: readonly DeliverySlot[];
  readonly supportContacts: readonly SupportContact[];
  readonly privacyContact: string | null;
  readonly lowStockThreshold: number;
  readonly minAppVersion: string;
  readonly recommendedAppVersion: string | null;
  readonly customerStockDisplay: CustomerStockDisplay;
  /**
   * Общие для всех планшетов магазина настройки автосброса, секунды (08 §4.23.1; ADR-115, Р-09 (а)): ключи
   * `kiosk_idle_seconds`, `kiosk_idle_warning_seconds`, `kiosk_done_seconds`, иначе значения по умолчанию из кода.
   * Отдаётся всем ролям при любом `KIOSK_MODE`; лимиты кодов и часы работы не отдаются.
   */
  readonly kiosk: {
    readonly idleSeconds: number;
    readonly idleWarningSeconds: number;
    readonly doneSeconds: number;
  };
  readonly features: {
    readonly customerSelfService: boolean;
    readonly returnsFromPos: boolean;
    readonly qrProvider: QrProviderMode;
    readonly qrWebhook: boolean;
    readonly debtPaymentsFromPos: boolean;
    /** env `KIOSK_MODE` — режим «Планшет магазина» (только env, по умолчанию `false`; ADR-115). */
    readonly storeTablet: boolean;
  };
}

/** Значения по умолчанию при отсутствии/неверном значении ключа (08 §4.18.6 «Тип / по умолчанию»; seed 0001). */
export const PUBLIC_SETTINGS_DEFAULTS = {
  lowStockThreshold: 5,
  customerStockDisplay: 'status' as CustomerStockDisplay,
  returnsEnabled: true,
  qrEnabled: true,
} as const;

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
const CONTACT_KINDS = new Set(['phone', 'telegram', 'email']);

type PublicSettingsConfig = Pick<
  AppConfig,
  'CUSTOMER_SELF_SERVICE' | 'DEBT_PAYMENTS_FROM_POS' | 'QR_PROVIDER' | 'KIOSK_MODE' | 'QR_WEBHOOK_ENABLED'
>;

/**
 * Публичные настройки (RM-D-015; 08 §4.23.1, API-157; ядро §19.2, §24.2, §24.4). Источники: ключи `app_settings`
 * по таблице соответствия (public-settings.map.ts) через `SettingsReader` (кэш TTL — изменение действует без
 * перезапуска), версии — `AppVersionPolicy` (ключ, иначе env), флаги режима — только env
 * (`CUSTOMER_SELF_SERVICE`, `DEBT_PAYMENTS_FROM_POS`, `QR_PROVIDER`, `KIOSK_MODE`). Секреты, параметры OTP/лимиты (в
 * том числе `kiosk_otp_per_*`), часы работы `kiosk_working_hours` и внутренние адреса не читаются и не отдаются;
 * неверное значение ключа заменяется значением по умолчанию (не 500).
 */
@Injectable()
export class PublicSettingsService {
  constructor(
    private readonly settings: SettingsReader,
    private readonly versions: AppVersionPolicy,
    @Inject(APP_CONFIG) private readonly config: PublicSettingsConfig,
  ) {}

  async read(): Promise<PublicSettings> {
    const [slots, contacts, privacy, threshold, stockDisplay, returnsEnabled, qrEnabled, idle, warning, done] =
      await Promise.all([
        this.settings.get('delivery_slots'),
        this.settings.get('support_contacts'),
        this.settings.get('privacy_contact'),
        this.settings.get('low_stock_threshold'),
        this.settings.get('customer_stock_display'),
        this.settings.get('returns_enabled'),
        this.settings.get('qr.enabled'),
        this.settings.get('kiosk_idle_seconds'),
        this.settings.get('kiosk_idle_warning_seconds'),
        this.settings.get('kiosk_done_seconds'),
      ]);
    const policy = await this.versions.refresh();
    const qrOn = typeof qrEnabled === 'boolean' ? qrEnabled : PUBLIC_SETTINGS_DEFAULTS.qrEnabled;
    // Код контракта (`bank` → `bakai`, ADR-123): `QrProviderMode` OpenAPI не меняется.
    const provider: QrProviderMode = qrProviderCode(this.config.QR_PROVIDER);
    return {
      deliverySlots: coerceSlots(slots),
      supportContacts: coerceContacts(contacts),
      privacyContact: typeof privacy === 'string' && privacy.trim() !== '' ? privacy.trim() : null,
      lowStockThreshold:
        typeof threshold === 'number' && Number.isInteger(threshold) && threshold >= 0
          ? threshold
          : PUBLIC_SETTINGS_DEFAULTS.lowStockThreshold,
      minAppVersion: formatVersionHeader(policy.min, undefined) ?? '',
      recommendedAppVersion: formatVersionHeader(policy.recommended, undefined) ?? null,
      customerStockDisplay:
        stockDisplay === 'status' || stockDisplay === 'quantity'
          ? stockDisplay
          : PUBLIC_SETTINGS_DEFAULTS.customerStockDisplay,
      kiosk: {
        idleSeconds: kioskIntegerSetting('kiosk_idle_seconds', idle),
        idleWarningSeconds: kioskIntegerSetting('kiosk_idle_warning_seconds', warning),
        doneSeconds: kioskIntegerSetting('kiosk_done_seconds', done),
      },
      features: {
        customerSelfService: this.config.CUSTOMER_SELF_SERVICE,
        returnsFromPos: typeof returnsEnabled === 'boolean' ? returnsEnabled : PUBLIC_SETTINGS_DEFAULTS.returnsEnabled,
        qrProvider: qrOn ? provider : 'none',
        // По факту: маршрут вебхука банка зарегистрирован (QR_PROVIDER=bank и QR_WEBHOOK_ENABLED=true) и QR включён.
        qrWebhook: this.config.QR_PROVIDER === 'bank' && this.config.QR_WEBHOOK_ENABLED && qrOn,
        debtPaymentsFromPos: this.config.DEBT_PAYMENTS_FROM_POS,
        storeTablet: this.config.KIOSK_MODE,
      },
    };
  }

  /** Тело и `ETag` (хэш значений, 08 §2.8): слабый валидатор по SHA-256 канонического JSON. */
  async readWithEtag(): Promise<{ body: PublicSettings; etag: string }> {
    const body = await this.read();
    return { body, etag: etagOf(body) };
  }
}

export function etagOf(body: unknown): string {
  return `W/"${createHash('sha256').update(JSON.stringify(body)).digest('base64url').slice(0, 27)}"`;
}

function coerceSlots(raw: unknown): DeliverySlot[] {
  if (!Array.isArray(raw)) return [];
  const out: DeliverySlot[] = [];
  for (const s of raw) {
    if (s === null || typeof s !== 'object') continue;
    const { from, to } = s as Record<string, unknown>;
    if (typeof from === 'string' && typeof to === 'string' && HHMM.test(from) && HHMM.test(to)) out.push({ from, to });
  }
  return out;
}

function coerceContacts(raw: unknown): SupportContact[] {
  if (!Array.isArray(raw)) return [];
  const out: SupportContact[] = [];
  for (const c of raw) {
    if (c === null || typeof c !== 'object') continue;
    const { kind, value, label } = c as Record<string, unknown>;
    if (typeof kind !== 'string' || !CONTACT_KINDS.has(kind)) continue;
    if (typeof value !== 'string' || value.trim() === '' || value.length > 200) continue;
    out.push({
      kind: kind as SupportContact['kind'],
      value: value.trim(),
      ...(typeof label === 'string' && label.trim() !== '' ? { label: label.trim().slice(0, 100) } : {}),
    });
  }
  return out;
}
