import { main } from '../../scripts/seed_synthetic_catalog.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';

describe('scripts/seed_synthetic_catalog.ts — синтетический каталог через конвейер (тестовые данные)', () => {
  let f: CatalogFixture;
  const env = { APP_ENV: process.env.APP_ENV, DATABASE_URL: process.env.DATABASE_URL };
  const out: string[] = [];
  let write: typeof process.stdout.write;

  beforeAll(async () => {
    f = await startCatalogFixture({ database: 'seed_cli', skipLoad: true, includeFixtures: false, skuCount: 0 });
    write = process.stdout.write.bind(process.stdout);
    process.stdout.write = (chunk: string | Uint8Array) => {
      out.push(String(chunk));
      return true;
    };
  });

  afterAll(async () => {
    process.stdout.write = write;
    process.env.APP_ENV = env.APP_ENV;
    process.env.DATABASE_URL = env.DATABASE_URL;
    await f?.stop();
  });

  it('APP_ENV=prod или без APP_ENV → отказ (код 2), данные не пишутся', async () => {
    process.env.APP_ENV = 'prod';
    process.env.DATABASE_URL = f.url;
    expect(await main(['--sku', '10'])).toBe(2);
    delete process.env.APP_ENV;
    expect(await main(['--sku', '10'])).toBe(2);
    expect((await f.pool.query(`SELECT count(*)::int AS n FROM products`)).rows[0].n).toBe(0);
  });

  it('загрузка N SKU → код 0 и отчёт; повтор с тем же seed — без перезаписей; чужие товары → отказ без --force', async () => {
    process.env.APP_ENV = 'dev';
    process.env.DATABASE_URL = f.url;
    expect(await main(['--sku', '400', '--seed', '5'])).toBe(0);
    expect(out.join('')).toMatch(/ИТОГ: 400 SKU/);
    expect((await f.pool.query(`SELECT count(*)::int AS n FROM products`)).rows[0].n).toBe(400);
    const before = (await f.pool.query(`SELECT max(updated_at)::text AS t FROM products`)).rows[0].t;
    expect(await main(['--sku', '400', '--seed', '5'])).toBe(0);
    expect((await f.pool.query(`SELECT max(updated_at)::text AS t FROM products`)).rows[0].t).toBe(before);
    // Другой seed = другие ссылки: товары seed 5 для него «чужие».
    expect(await main(['--sku', '10', '--seed', '6'])).toBe(2);
  });
});
