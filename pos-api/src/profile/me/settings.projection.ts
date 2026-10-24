import type { UserProfileRow } from '../../users/users.types.js';

export type ScannerMode = 'hid' | 'camera';
export type ScannerSuffix = 'enter' | 'tab' | 'none';
export type PrintPaper = 'a4' | 'thermal80';
export type CatalogView = 'grid' | 'list' | 'compact';
export type Locale = 'ru' | 'ky' | 'en';

/** contracts/openapi `Settings` (08 §3.14, §4.3.4): проекция `user_profiles.settings` + `user_profiles.locale`. */
export interface SettingsDto {
  readonly locale: Locale;
  readonly scanner: { readonly mode: ScannerMode; readonly suffix: ScannerSuffix };
  readonly scanAddsToCart: boolean;
  readonly printer: { readonly defaultFormat: PrintPaper; readonly autoPrint: boolean };
  readonly catalogView: CatalogView;
  readonly defaultWarehouseId: string | null;
  readonly idleLockMinutes: number;
  readonly rowVersion: number;
}

/** Хранимый вид `user_profiles.settings` (jsonb; 07 §5.2: ключ `scan_adds_to_cart`, склад — `defaultWarehouseId`). */
export interface StoredSettings {
  readonly scanner?: { readonly mode?: unknown; readonly suffix?: unknown };
  readonly scan_adds_to_cart?: unknown;
  readonly printer?: { readonly defaultFormat?: unknown; readonly autoPrint?: unknown };
  readonly catalogView?: unknown;
  readonly defaultWarehouseId?: unknown;
  readonly idleLockMinutes?: unknown;
}

export interface SettingsContext {
  readonly kind: 'staff' | 'customer';
  readonly roles: readonly string[];
  readonly platform?: string | null;
  /** `SESSION_IDLE_LOCK_MINUTES` (30) — значение по умолчанию и максимум для `staff`. */
  readonly staffIdleMinutes: number;
  readonly customerIdleMinutes: number;
}

function pick<T extends string>(v: unknown, allowed: readonly T[], fallback: T): T {
  return typeof v === 'string' && (allowed as readonly string[]).includes(v) ? (v as T) : fallback;
}

function asObject(v: unknown): Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

/**
 * Значения по умолчанию (08 §3.14; 07 §5.2): `scanAddsToCart` — `cashier` true, прочие false (ядро §19.4);
 * сканер Windows — HID, мобильные — камера; бумага кассира — `thermal80`; idle — `SESSION_IDLE_LOCK_MINUTES`.
 */
export function settingsFromProfile(profile: UserProfileRow | undefined, ctx: SettingsContext): SettingsDto {
  const s = asObject(profile?.settings) as StoredSettings;
  const scanner = asObject(s.scanner);
  const printer = asObject(s.printer);
  const cashier = ctx.roles.includes('cashier');
  const idleDefault = ctx.kind === 'staff' ? ctx.staffIdleMinutes : ctx.customerIdleMinutes;
  const idle = typeof s.idleLockMinutes === 'number' && Number.isInteger(s.idleLockMinutes) ? s.idleLockMinutes : null;
  return {
    locale: pick(profile?.locale, ['ru', 'ky', 'en'] as const, 'ru'),
    scanner: {
      mode: pick(scanner.mode, ['hid', 'camera'] as const, ctx.platform === 'windows' ? 'hid' : 'camera'),
      suffix: pick(scanner.suffix, ['enter', 'tab', 'none'] as const, 'enter'),
    },
    scanAddsToCart: typeof s.scan_adds_to_cart === 'boolean' ? s.scan_adds_to_cart : cashier,
    printer: {
      defaultFormat: pick(printer.defaultFormat, ['a4', 'thermal80'] as const, cashier ? 'thermal80' : 'a4'),
      autoPrint: typeof printer.autoPrint === 'boolean' ? printer.autoPrint : false,
    },
    catalogView: pick(s.catalogView, ['grid', 'list', 'compact'] as const, 'grid'),
    defaultWarehouseId: typeof s.defaultWarehouseId === 'string' ? s.defaultWarehouseId : null,
    idleLockMinutes: idle ?? idleDefault,
    // Версия настроек = `user_profiles.row_version` (07 §8.3: любой UPDATE строки профиля под pos_app обязан
    // увеличить row_version — триггер check_row_version), поэтому PATCH профиля и PUT настроек делят одну версию.
    rowVersion: profile?.rowVersion ?? 0,
  };
}

export function storedFromSettings(dto: Omit<SettingsDto, 'locale' | 'rowVersion'>): StoredSettings {
  return {
    scanner: { mode: dto.scanner.mode, suffix: dto.scanner.suffix },
    scan_adds_to_cart: dto.scanAddsToCart,
    printer: { defaultFormat: dto.printer.defaultFormat, autoPrint: dto.printer.autoPrint },
    catalogView: dto.catalogView,
    defaultWarehouseId: dto.defaultWarehouseId,
    idleLockMinutes: dto.idleLockMinutes,
  };
}
