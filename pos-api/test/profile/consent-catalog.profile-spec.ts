import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { CONSENT_KIND_VALUES } from '../../src/common/enums.js';
import { CONSENT_CATALOG } from '../../src/profile/consents/consent-catalog.js';
import {
  birthYearErrors,
  fullNameErrors,
  pinMinLength,
  pinWeakReason,
} from '../../src/profile/domain/profile-rules.js';
import { maskCustomerName } from '../../src/profile/customer-link.reader.js';

interface MdSection {
  readonly kind: string;
  readonly version: string;
  readonly declared: string;
  readonly actual: string;
}

/** Разбор contracts/legal/consents_ru.md: `## <kind> — версия <v>`, `- sha256: \`hex\``, блок ```text. */
function parseConsentsMd(): MdSection[] {
  const path = fileURLToPath(new URL('../../../contracts/legal/consents_ru.md', import.meta.url));
  const lines = readFileSync(path, 'utf8').replace(/\r\n/g, '\n').split('\n');
  const out: MdSection[] = [];
  let cur: { kind: string; version: string; declared?: string } | null = null;
  let buf: string[] | null = null;
  for (const l of lines) {
    const head = /^## ([a-z_]+) — версия (\S+)$/.exec(l);
    if (head) {
      cur = { kind: head[1] ?? '', version: head[2] ?? '' };
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
        kind: cur.kind,
        version: cur.version,
        declared: cur.declared ?? '',
        actual: createHash('sha256').update(text, 'utf8').digest('hex'),
      });
      cur = null;
      buf = null;
      continue;
    }
    if (buf) buf.push(l);
  }
  return out;
}

describe('тексты согласий contracts/legal/consents_ru.md ↔ каталог версий (07 DATA-113, 11 §10.3)', () => {
  const sections = parseConsentsMd();

  it('каждый раздел: объявленный sha256 = SHA-256 текста; вид — из consent_kind 07; face_scan отсутствует (R2)', () => {
    expect(sections.length).toBeGreaterThanOrEqual(4);
    for (const s of sections) {
      expect(s.declared, s.kind).toBe(s.actual);
      expect(CONSENT_KIND_VALUES as readonly string[]).toContain(s.kind);
    }
    expect(sections.map((s) => s.kind)).not.toContain('face_scan');
  });

  it('каталог кода содержит ровно версии и хэши файла; текущая версия каждого вида есть в файле', () => {
    for (const [kind, entry] of Object.entries(CONSENT_CATALOG)) {
      expect(
        entry?.versions.some((v) => v.version === entry.current),
        kind,
      ).toBe(true);
      for (const v of entry?.versions ?? []) {
        const s = sections.find((x) => x.kind === kind && x.version === v.version);
        expect(s, `${kind}@${v.version}`).toBeDefined();
        expect(v.sha256).toBe(s?.actual);
      }
    }
    for (const s of sections) expect(CONSENT_CATALOG[s.kind as keyof typeof CONSENT_CATALOG]).toBeDefined();
  });
});

describe('правила полей профиля (09 §7.1, §9.6; ядро §19.3) — unit', () => {
  it('PIN: длина по роли, одинаковые цифры, последовательности, год рождения (T-BIO-011)', () => {
    expect(pinMinLength('staff', 6)).toBe(6);
    expect(pinMinLength('customer', 6)).toBe(4);
    expect(pinWeakReason('0000', 4)).toBe('repeated');
    expect(pinWeakReason('111111', 4)).toBe('repeated');
    expect(pinWeakReason('1234', 4)).toBe('sequence');
    expect(pinWeakReason('123456', 4)).toBe('sequence');
    expect(pinWeakReason('654321', 4)).toBe('sequence');
    expect(pinWeakReason('9876', 4)).toBe('sequence');
    expect(pinWeakReason('1990', 4, 1990)).toBe('birth_year');
    expect(pinWeakReason('719904', 4, 1990)).toBe('birth_year');
    expect(pinWeakReason('5830', 6)).toBe('length');
    expect(pinWeakReason('12a4', 4)).toBe('length');
    expect(pinWeakReason('5830', 4)).toBeNull();
    expect(pinWeakReason('804613', 6, 1990)).toBeNull();
    expect(pinWeakReason('1357', 4)).toBeNull();
  });

  it('год рождения: 1920 ≤ год ≤ текущий − 14', () => {
    const now = new Date('2026-10-22T00:00:00Z');
    expect(birthYearErrors(1920, now)).toEqual([]);
    expect(birthYearErrors(2012, now)).toEqual([]);
    expect(birthYearErrors(2013, now)[0]).toMatchObject({ rule: 'birth_year_range', params: { max: 2012 } });
    expect(birthYearErrors(1919, now)[0]?.rule).toBe('birth_year_range');
  });

  it('ФИО: буквы кириллицы (вкл. кыргызские)/латиницы, пробел, дефис, апостроф; 2…150; без цифр', () => {
    expect(fullNameErrors('Абдуллаев Абдулла')).toEqual([]);
    expect(fullNameErrors("O'Neil-Smith")).toEqual([]);
    expect(fullNameErrors('Үмөт Ңайзабеков')).toEqual([]);
    expect(fullNameErrors('А')[0]?.rule).toBe('full_name_length');
    expect(fullNameErrors('x'.repeat(151))[0]?.rule).toBe('full_name_length');
    expect(fullNameErrors('Иван 2')[0]?.rule).toBe('full_name_format');
    expect(fullNameErrors('Иван--Петров')[0]?.rule).toBe('full_name_format');
  });

  it('маска наименования карточки 1С (08 §4.2.2)', () => {
    expect(maskCustomerName('ОсОО «Строймаркет»')).toBe('ОсОО «Стр***»');
    expect(maskCustomerName('ИП Абдыкадыров')).toBe('ИП Абд***');
    expect(maskCustomerName('Иванов Иван')).toBe('Ива***');
  });
});
