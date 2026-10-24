import { describe, expect, it } from 'vitest';
import { cursorFingerprint, SearchCursorCodec } from '../../src/catalog/search/search-cursor.js';
import { buildStageQuery, tsQueryExpr } from '../../src/catalog/search/search.repository.js';
import { stagePlan } from '../../src/catalog/search/search.service.js';
import {
  classifyQuery,
  normSku,
  QueryTooShortError,
  queryWords,
  switchLayout,
  translitCyrToLat,
  translitLatToCyr,
  wordVariants,
} from '../../src/catalog/search/search-text.js';
import { SqlParams } from '../../src/catalog/search/sql-params.js';
import type { CatalogViewer } from '../../src/catalog/common/catalog-viewer.js';

const viewer: CatalogViewer = {
  userId: '00000000-0000-4000-8000-000000000001',
  role: 'seller',
  isCustomer: false,
  canReadPrice: true,
  canReadAllPrices: false,
  priceList: { id: '00000000-0000-4000-8000-000000000002', name: 'Розничная' },
  warehouse: { id: '00000000-0000-4000-8000-000000000003', name: 'Основной склад' },
  stockDisplay: 'full',
  lowStockThreshold: '5',
};

describe('D-31: классификация запроса (07 §10.3)', () => {
  it('штрихкод: только цифры 4–14 → barcode, затем артикул', () => {
    const q = classifyQuery(' 2100000001002 ');
    expect(q).toMatchObject({ raw: '2100000001002', digits: true, barcodeCandidate: true, skuCandidate: true });
    expect(stagePlan(q)).toEqual(['barcode', 'sku', 'fts', 'trgm']);
  });

  it('артикул: буквы/цифры/дефис/точка/слеш без пробелов', () => {
    expect(classifyQuery('F4252')).toMatchObject({ barcodeCandidate: false, skuCandidate: true, skuNorm: 'F4252' });
    expect(classifyQuery('СМ-12 a').skuCandidate).toBe(false); // пробел — не артикул (ветка FTS)
    expect(classifyQuery('g1017-8').skuNorm).toBe('G10178');
    expect(stagePlan(classifyQuery('Frap F4252'))).toEqual(['fts', 'trgm']);
  });

  it('norm_sku: верхний регистр без пробелов и -_./ (DATA-115: «СМ-12 a» → «СМ12A»)', () => {
    expect(normSku('СМ-12 a')).toBe('СМ12A');
    expect(normSku('a_b.c/d-e f')).toBe('ABCDEF');
  });

  it('короткий запрос: < 2 символов текста → q_too_short; цифра — допустима', () => {
    expect(() => classifyQuery('с')).toThrow(QueryTooShortError);
    expect(() => classifyQuery('   ')).toThrow(QueryTooShortError);
    expect(() => classifyQuery('')).toThrow(QueryTooShortError);
    expect(classifyQuery('5')).toMatchObject({ digits: true, skuCandidate: true, barcodeCandidate: false });
    expect(classifyQuery('см').skuCandidate).toBe(true);
  });

  it('слова: lower, ё→е, только буквы/цифры (операторы tsquery отбрасываются), не больше 8', () => {
    expect(queryWords("Смеситель & | ! ( ) :* <-> 'Frap'")).toEqual(['смеситель', 'frap']);
    expect(queryWords('Ёршик ЁЛКА')).toEqual(['ершик', 'елка']);
    expect(queryWords('a b c d e f g h i j').length).toBe(8);
    expect(queryWords("'; DROP TABLE products; --")).toEqual(['drop', 'table', 'products']);
  });
});

describe('варианты слова для FTS: транслитерация и раскладка', () => {
  it('«фрап» → frap; «frap» → фрап; раскладка «cvtcbntkm» → «смеситель»', () => {
    expect(translitCyrToLat('фрап')).toBe('frap');
    expect(translitLatToCyr('frap')).toBe('фрап');
    expect(translitLatToCyr('santek')).toBe('сантек');
    expect(switchLayout('cvtcbntkm')).toBe('смеситель');
    expect(switchLayout('акфз')).toBe('frap');
    expect(wordVariants('фрап')).toEqual(['фрап', 'frap', 'ahfg']);
    expect(wordVariants('f4252')).toEqual(['f4252']);
    expect(wordVariants('20')).toEqual(['20']);
  });
});

describe('SQL строится только с параметрами', () => {
  // 12 T-SEC-027, T-CAT-015 (параметризованные запросы)
  it('tsquery: значения — параметры $n, в тексте SQL нет пользовательских строк', () => {
    const p = new SqlParams();
    const sql = tsQueryExpr(['смеситель', 'фрап'], p)!;
    expect(sql).not.toContain('смеситель');
    expect(sql).not.toContain('фрап');
    expect(p.values).toContain('смеситель');
    expect(p.values).toContain('фрап:*');
    expect(p.values).toContain('frap:*');
  });

  // 12 T-SEC-027 (фильтры и сортировка — параметры)
  it('запрос ступени: q, фильтры и курсор не попадают в текст SQL', () => {
    const evil = "x'; DROP TABLE products; --";
    for (const stage of ['barcode', 'sku', 'fts', 'trgm'] as const) {
      const built = buildStageQuery({
        stage,
        query: {
          raw: evil,
          digits: false,
          barcodeCandidate: false,
          skuCandidate: true,
          skuNorm: evil,
          words: ['x', 'drop'],
        },
        filters: { includeSubcategories: true, brand: [evil], attr: { [evil]: evil }, priceMin: '1.00', inStock: true },
        viewer,
        sort: 'price:asc',
        limit: 40,
        after: ['0', '10.00', '00000000-0000-4000-8000-000000000009'],
      });
      expect(built.text).not.toContain('DROP');
      expect(built.values).toContain(evil);
    }
  });
});

describe('курсор', () => {
  const codec = new SearchCursorCodec((body) => `mac-${body}`.padEnd(40, '0'));
  const fp = cursorFingerprint({ q: 'x' });

  it('кодирует и проверяет подпись, сортировку и отпечаток запроса', () => {
    const c = codec.encode({ stage: 'fts', sort: 'relevance:desc', fingerprint: fp, keys: ['0.1', 'id'] });
    expect(codec.decode(c, { sort: 'relevance:desc', fingerprint: fp })).toMatchObject({
      stage: 'fts',
      keys: ['0.1', 'id'],
    });
    expect(() => codec.decode(c, { sort: 'name:asc', fingerprint: fp })).toThrow();
    expect(() => codec.decode(c, { sort: 'relevance:desc', fingerprint: 'other' })).toThrow();
    expect(() => codec.decode(`${c}x`, { sort: 'relevance:desc', fingerprint: fp })).toThrow();
    expect(() => codec.decode('garbage', { sort: 'relevance:desc', fingerprint: fp })).toThrow();
  });

  it('содержимое зашифровано: остаток ключа available:desc не читается из курсора (ревью E-api-1); подмена байта → отказ', () => {
    const c = codec.encode({
      stage: 'fts',
      sort: 'available:desc',
      fingerprint: fp,
      keys: ['0', '757.000', '00000000-0000-4000-8000-000000000009'],
    });
    const raw = Buffer.from(c, 'base64url').toString('latin1');
    expect(raw).not.toContain('757.000');
    expect(raw).not.toContain('available');
    expect(c).not.toContain('.');
    const flipped = Buffer.from(c, 'base64url');
    flipped[20] = (flipped[20] ?? 0) ^ 1;
    expect(() => codec.decode(flipped.toString('base64url'), { sort: 'available:desc', fingerprint: fp })).toThrow();
  });

  it('вариант ступени trgm (исправленные слова / исходный запрос) переживает курсор (ревью E-api-2)', () => {
    const a = codec.encode({
      stage: 'trgm',
      sort: 'relevance:desc',
      fingerprint: fp,
      keys: ['1', 'id'],
      corrected: null,
    });
    expect(codec.decode(a, { sort: 'relevance:desc', fingerprint: fp }).corrected).toBeNull();
    const b = codec.encode({
      stage: 'trgm',
      sort: 'relevance:desc',
      fingerprint: fp,
      keys: ['1', 'id'],
      corrected: ['радиатор', 'смеситель'],
    });
    expect(codec.decode(b, { sort: 'relevance:desc', fingerprint: fp }).corrected).toEqual(['радиатор', 'смеситель']);
    expect(
      codec.decode(codec.encode({ stage: 'fts', sort: 's', fingerprint: fp, keys: ['1'] }), {
        sort: 's',
        fingerprint: fp,
      }).corrected,
    ).toBeUndefined();
  });
});
