import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-003: пайплайн фото товаров (sharp → images/{sha256}/{size}.webp, product_images, sync_errors) на embedded
// PostgreSQL 17 со всеми миграциями. Запуск из pos-api/: `npm run test:images`. Изображения — синтетические (sharp),
// 1С — тестовый шлюз getImage (не реальная интеграция).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/images/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 240_000,
  },
});
