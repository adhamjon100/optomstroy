import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { IMAGE_SIZE_NAMES } from '../../src/sync/images/image-sizes.js';
import { ImageStore } from '../../src/sync/images/image-store.js';

/**
 * RM-E-003 / DEPLOY-041: статическая проверка блока `/images` в `infra/caddy/Caddyfile` (на машине агента нет
 * `caddy` — `caddy validate` и `curl -I` выполняются на контуре, см. отчёт). Проверяется соответствие путей
 * хранилища `ImageStore` маршруту прокси и заголовок `Cache-Control: public, max-age=31536000, immutable`.
 */
const caddyfile = readFileSync(fileURLToPath(new URL('../../../infra/caddy/Caddyfile', import.meta.url)), 'utf8');

function block(name: string): string {
  const start = caddyfile.indexOf(name);
  expect(start).toBeGreaterThan(-1);
  let depth = 0;
  for (let i = caddyfile.indexOf('{', start); i < caddyfile.length; i++) {
    if (caddyfile[i] === '{') depth++;
    if (caddyfile[i] === '}' && --depth === 0) return caddyfile.slice(start, i + 1);
  }
  throw new Error(`блок ${name} не закрыт`);
}

describe('Caddyfile: раздача /images (D-30, 08 §4.4.7, 16 DEPLOY-041)', () => {
  // 12 T-SEC-046 (GET /images/../secrets/x, /images/ — вне матчера)
  it('матчер — только GET/HEAD и канонический путь /images/{sha256}/{thumb|card|full}', () => {
    const m = block('@image {');
    expect(m).toMatch(/method GET HEAD/);
    const re = /path_regexp\s+(\S+)/.exec(m)?.[1];
    expect(re).toBeDefined();
    const rx = new RegExp(re!);
    const sha = 'a'.repeat(64);
    for (const s of IMAGE_SIZE_NAMES) {
      expect(rx.test(`/images/${sha}/${s}`)).toBe(true);
      expect(rx.test(`/images/${sha}/${s}.webp`)).toBe(true);
    }
    for (const bad of [
      `/images/${sha}/`,
      `/images/${sha}`,
      `/images/${sha}/orig`,
      `/images/../etc/passwd`,
      `/images/${sha}/.card.x.tmp`,
    ])
      expect(rx.test(bad)).toBe(false);
  });

  // 12 T-CAT-006 (Cache-Control immutable — конфигурация; curl -I на Caddy не выполнялся)
  it('file_server из тома media с Cache-Control immutable на найденный файл, прочее под /images → 404', () => {
    const h = block('handle @image {');
    expect(h).toMatch(/root \* \/srv\/media\r?$/m);
    expect(h).toMatch(/try_files \{path\}\.webp \{path\}/);
    expect(h).toMatch(/header @stored Cache-Control "public, max-age=31536000, immutable"/);
    expect(h).toMatch(/file_server/);
    expect(block('handle /images/* {')).toMatch(/respond 404/);
    // Путь хранилища pos-worker (MEDIA_DIR=/data/media → /srv/media в caddy) совпадает с маршрутом.
    const store = new ImageStore('/srv/media');
    const sha = 'b'.repeat(64);
    expect(store.fileOf(sha, 'card').replace(/\\/g, '/')).toMatch(new RegExp(`/srv/media/images/${sha}/card\\.webp$`));
    expect(ImageStore.storageKey(sha)).toBe(`images/${sha}`);
  });
});
