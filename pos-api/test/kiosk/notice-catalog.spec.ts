import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CONSENT_KIND_VALUES } from '../../src/common/enums.js';
import {
  KIOSK_ORDER_NOTICE_CODE,
  kioskNoticeSha256,
  kioskNoticeVersion,
  NOTICE_CATALOG,
} from '../../src/kiosk/otp/notice-catalog.js';

interface MdSection {
  readonly code: string;
  readonly version: string;
  readonly declared: string;
  readonly actual: string;
  readonly paragraphs: number;
}

const NOTICES_MD = fileURLToPath(new URL('../../../contracts/legal/notices_ru.md', import.meta.url));

/**
 * Разбор contracts/legal/notices_ru.md (формат consents_ru.md — test/profile/consent-catalog.profile-spec.ts):
 * `## <код> — версия <v>`, `- sha256: \`hex\``, блок ```text (концы строк LF, без начальных и конечных пустых строк).
 */
function parseNoticesMd(): MdSection[] {
  const lines = readFileSync(NOTICES_MD, 'utf8').replace(/\r\n/g, '\n').split('\n');
  const out: MdSection[] = [];
  let cur: { code: string; version: string; declared?: string } | null = null;
  let buf: string[] | null = null;
  for (const l of lines) {
    const head = /^## ([a-z_]+) — версия (\S+)$/.exec(l);
    if (head) {
      cur = { code: head[1] ?? '', version: head[2] ?? '' };
      continue;
    }
    const sha = /^- sha256: `([0-9a-f]{64})`$/.exec(l);
    if (cur && sha) cur.declared = sha[1];
    if (cur && l === '```text') {
      buf = [];
      continue;
    }
    if (cur && buf && l === '```') {
      const text = buf.join('\n').replace(/^\n+|\n+$/g, '');
      out.push({
        code: cur.code,
        version: cur.version,
        declared: cur.declared ?? '',
        actual: createHash('sha256').update(text, 'utf8').digest('hex'),
        paragraphs: text.split('\n\n').length,
      });
      cur = null;
      buf = null;
      continue;
    }
    if (buf) buf.push(l);
  }
  return out;
}

/**
 * Каталог версий текста информирования планшета магазина (11 PRIV-032; 10 KIOSK-022; ADR-115 п. 16; 12 T-KIOSK-041):
 * сервер принимает в `POST /kiosk/order-otp` ровно версии файла `contracts/legal/notices_ru.md` и хэширует ровно его
 * текст — образ pos-api не содержит `contracts/`, поэтому каталог скомпилирован в код и сверяется здесь.
 */
describe('T-KIOSK-041 notice catalog: каталог версий сервера = contracts/legal/notices_ru.md (ADR-115 п. 16)', () => {
  const sections = parseNoticesMd();

  it('каждый раздел: объявленный sha256 = SHA-256 текста блока; код — kiosk_order_notice, не значение consent_kind', () => {
    expect(sections.length).toBeGreaterThanOrEqual(1);
    for (const s of sections) {
      expect(s.declared, `${s.code}@${s.version}`).toBe(s.actual);
      expect(s.code).toBe(KIOSK_ORDER_NOTICE_CODE);
      expect(s.version).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      // информирование, а не согласие: в consents не пишется (11 §10.3)
      expect(CONSENT_KIND_VALUES as readonly string[]).not.toContain(s.code);
    }
    const v1 = sections.find((s) => s.version === '2026-11-04');
    expect(v1?.paragraphs).toBe(9);
  });

  it('каталог кода содержит ровно версии и хэши файла; текущая версия есть в каталоге и в файле', () => {
    const entry = NOTICE_CATALOG.kiosk_order_notice;
    expect(entry.code).toBe(KIOSK_ORDER_NOTICE_CODE);
    expect(entry.versions.some((v) => v.version === entry.current)).toBe(true);
    const fromFile = sections
      .filter((s) => s.code === KIOSK_ORDER_NOTICE_CODE)
      .map((s) => ({ version: s.version, sha256: s.actual }))
      .sort((a, b) => a.version.localeCompare(b.version));
    const inCode = [...entry.versions].sort((a, b) => a.version.localeCompare(b.version));
    expect(inCode).toEqual(fromFile);
    for (const v of inCode) expect(v.sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  it('версия 2026-11-04 принимается, неизвестная и не строка — нет; sha256 — для orders.pd_notice_sha256', () => {
    expect(kioskNoticeVersion('2026-11-04')).toEqual({
      version: '2026-11-04',
      sha256: '7ac18a5d3905144afc88b8a9140a25eb5b74125be528b19208d4bbfe6c629af8',
    });
    expect(kioskNoticeSha256('2026-11-04')).toBe('7ac18a5d3905144afc88b8a9140a25eb5b74125be528b19208d4bbfe6c629af8');
    for (const bad of ['2026-11-05', '2026-10-01', '', ' 2026-11-04', '2026-11-04 ', null, undefined, 20261104]) {
      expect(kioskNoticeVersion(bad), String(bad)).toBeUndefined();
    }
    expect(kioskNoticeSha256('1999-01-01')).toBeUndefined();
  });
});
