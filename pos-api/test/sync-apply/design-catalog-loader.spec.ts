import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { categoryOrder, photoPlan, validateDesignSpec } from '../../scripts/design_catalog.js';
import { designCatalogOf, readDesignSpec } from '../../scripts/load_catalog_fixtures.js';

/**
 * Режим «каталог по макету» загрузчика Windows-демо (`scripts/load_catalog_fixtures.ts --spec`, ADR-114; ревью RC-09):
 * спецификация `demo/catalog/design-catalog.json` разбирается и проверяется, генератор совпадает с зеркальными
 * константами (`designCatalogOf`), порядок папок и план фото (товары и картинки категорий) — по спецификации, файлы
 * фото на месте и с тем же sha256 (загрузчик их не подменяет). Без БД: применение к PostgreSQL (`sort_order`,
 * `categories.image_id`, избранное) — `loadCatalogFixtures(pool, { design })` на embedded PostgreSQL, отдельный
 * прогон стенда. Данные — тестовые данные демо.
 */
const SPEC = fileURLToPath(new URL('../../../demo/catalog/design-catalog.json', import.meta.url));
const DIR = path.dirname(SPEC);

describe('loadCatalogFixtures({ design }) — каталог по макету без БД (ADR-114, RC-09)', () => {
  const { spec, specSha256 } = readDesignSpec(SPEC);

  it('спецификация разобрана: профиль, 8 корней прототипа, 78 товаров, sha256 файла', () => {
    expect(spec.profile).toMatch(/^design-/);
    expect(specSha256).toBe(createHash('sha256').update(readFileSync(SPEC)).digest('hex'));
    expect(validateDesignSpec(spec)).toEqual([]);
    expect(spec.categories.map((c) => c.name)).toEqual([
      'Отопление',
      'Сантехника',
      'Водоснабжение',
      'Электрика',
      'Вентиляция',
      'Строительные материалы',
      'Инструменты',
      'Крепеж и фурнитура',
    ]);
    expect(spec.products).toHaveLength(78);
    expect(spec.favorites).toContain('SL1001');
  });

  it('генератор = зеркальные константы; папки — корни и подкатегории в порядке макета', () => {
    const catalog = designCatalogOf(spec);
    const folders = spec.categories.length + spec.categories.reduce((n, c) => n + c.subs.length, 0);
    expect(catalog.categories).toHaveLength(folders);
    const order = categoryOrder(spec, catalog);
    expect(order).toHaveLength(folders);
    expect(new Set(order.map((o) => o.onecRef)).size).toBe(folders);
    const roots = order.filter((o) => !o.path.includes('/'));
    expect(roots.map((o) => o.sortOrder)).toEqual(spec.categories.map((c) => c.sortOrder));
    // Повторная сборка из той же спецификации — те же ссылки 1С (детерминированно по refSeed).
    expect(categoryOrder(spec, designCatalogOf(spec)).map((o) => o.onecRef)).toEqual(order.map((o) => o.onecRef));
  });

  it('план фото: картинки категорий и фото товаров — файлы спецификации с тем же sha256', () => {
    const plan = photoPlan(spec, designCatalogOf(spec));
    const roots = spec.categories.filter((c) => c.image !== null).length;
    const subs = spec.categories.reduce((n, c) => n + c.subs.filter((s) => s.image !== null).length, 0);
    expect(plan.categories).toHaveLength(roots + subs);
    expect(plan.products).toHaveLength(spec.products.filter((p) => p.photo !== null).length);
    expect(plan.categories.find((c) => c.owner === 'plumbing')?.photo).toBe('cat-plumbing');
    for (const item of [...plan.categories, ...plan.products]) {
      const bytes = readFileSync(path.join(DIR, item.file));
      expect(createHash('sha256').update(bytes).digest('hex')).toBe(item.sha256);
    }
  });

  it('ошибка спецификации — исключение с причиной (каталог не загружается молча)', () => {
    const broken = { ...spec, refSeed: 1, photos: [...spec.photos, spec.photos[0]] };
    const errs = validateDesignSpec(broken);
    expect(errs.some((e) => e.includes('refSeed'))).toBe(true);
    expect(errs.some((e) => e.includes('повторяется'))).toBe(true);
  });
});
