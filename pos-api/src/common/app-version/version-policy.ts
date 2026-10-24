/**
 * Политика версий клиента (RM-C-015; 08 §2.3, §2.11; ядро R0 §16 п. 4, §18.2 п. 12, §20.2 п. 14).
 * Формат значения `MIN_APP_VERSION` / `RECOMMENDED_APP_VERSION` / `app_settings.min_app_version`:
 * `platform=semver` через запятую, например `android=1.2.0,windows=1.2.0`.
 */
export const CLIENT_PLATFORMS = ['android', 'windows', 'ios'] as const;
export type ClientPlatform = (typeof CLIENT_PLATFORMS)[number];

export type PlatformVersions = Readonly<Partial<Record<ClientPlatform, string>>>;

const SEMVER_RE =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

export interface SemVer {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
  readonly prerelease: readonly string[];
}

export function isClientPlatform(value: unknown): value is ClientPlatform {
  return typeof value === 'string' && (CLIENT_PLATFORMS as readonly string[]).includes(value);
}

/** Разбор SemVer 2.0.0; build-метаданные (`+87`) на сравнение не влияют. */
export function parseSemVer(value: string): SemVer | null {
  const m = SEMVER_RE.exec(value.trim());
  if (!m) return null;
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    prerelease: m[4] ? m[4].split('.') : [],
  };
}

/** Сравнение по правилам приоритета SemVer 2.0.0 §11: <0 — a < b, 0 — равны, >0 — a > b. */
export function compareSemVer(a: SemVer, b: SemVer): number {
  for (const k of ['major', 'minor', 'patch'] as const) {
    if (a[k] !== b[k]) return a[k] < b[k] ? -1 : 1;
  }
  const pa = a.prerelease;
  const pb = b.prerelease;
  if (pa.length === 0 && pb.length === 0) return 0;
  if (pa.length === 0) return 1;
  if (pb.length === 0) return -1;
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i];
    const y = pb[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      const d = Number(x) - Number(y);
      if (d !== 0) return d < 0 ? -1 : 1;
    } else if (xn !== yn) {
      return xn ? -1 : 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

export class VersionListFormatError extends Error {}

/** Разбор `android=1.2.0,windows=1.2.0`. Пустая строка → пустая политика. Ошибка формата → исключение. */
export function parsePlatformVersions(value: string): PlatformVersions {
  const result: Partial<Record<ClientPlatform, string>> = {};
  const trimmed = value.trim();
  if (trimmed === '') return result;
  for (const part of trimmed.split(',')) {
    const [platformRaw, versionRaw, ...rest] = part.split('=');
    const platform = platformRaw?.trim();
    const version = versionRaw?.trim();
    if (rest.length > 0 || !platform || !version) {
      throw new VersionListFormatError(`ожидается platform=semver, получено «${part.trim()}»`);
    }
    if (!isClientPlatform(platform)) {
      throw new VersionListFormatError(
        `неизвестная платформа «${platform}» (допустимо: ${CLIENT_PLATFORMS.join(', ')})`,
      );
    }
    if (parseSemVer(version) === null) {
      throw new VersionListFormatError(`«${version}» для ${platform} — не semver`);
    }
    if (result[platform] !== undefined) {
      throw new VersionListFormatError(`платформа «${platform}» указана дважды`);
    }
    result[platform] = version;
  }
  return result;
}

/**
 * Значение заголовков `X-Min-App-Version` / `X-Recommended-App-Version`: при известной платформе —
 * пара для неё (`android=1.2.0`), иначе — все платформы. `undefined` — заголовок не отправляется.
 */
export function formatVersionHeader(
  policy: PlatformVersions,
  platform: ClientPlatform | undefined,
): string | undefined {
  if (platform !== undefined) {
    const v = policy[platform];
    return v === undefined ? undefined : `${platform}=${v}`;
  }
  const pairs = CLIENT_PLATFORMS.filter((p) => policy[p] !== undefined).map((p) => `${p}=${policy[p]}`);
  return pairs.length > 0 ? pairs.join(',') : undefined;
}

/** true — версия клиента ниже минимальной для платформы (→ 426). Неразборчивая версия клиента — не ниже (решает валидация). */
export function isBelowMinimum(policy: PlatformVersions, platform: ClientPlatform, clientVersion: SemVer): boolean {
  const min = policy[platform];
  if (min === undefined) return false;
  const minParsed = parseSemVer(min);
  return minParsed !== null && compareSemVer(clientVersion, minParsed) < 0;
}
