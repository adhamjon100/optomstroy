import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, RM-F-004 / RM-F-012 п. 5: печатные документы заказа (PdfRenderer на pdfkit, шаблоны assets/templates/pdf,
// GET /orders/{id}/documents/*.pdf) — unit-тесты рендера и e2e на стенде test/support/pos-fixture.ts (embedded
// PostgreSQL 17 + синтетический каталог — тестовые данные). Запуск из pos-api/: `npm run test:documents`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/documents/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
