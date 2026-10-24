import 'reflect-metadata';
import { API_PORT, createApp } from './bootstrap/create-app.js';
import { type AppConfig, ConfigError, loadAppConfig } from './common/config/app-config.js';

/**
 * Точка входа pos-api (`node dist/main.js`). Конфигурация валидируется до создания приложения: при ошибке —
 * понятное сообщение в stderr (только имена переменных и причины, без значений) и код выхода 1 (RM-C-009 п. 5).
 */
async function bootstrap(): Promise<void> {
  let config: AppConfig;
  try {
    config = loadAppConfig();
  } catch (e) {
    if (e instanceof ConfigError) {
      console.error(e.message);
      process.exit(1);
    }
    throw e;
  }
  const app = await createApp(config);
  await app.listen(API_PORT, '0.0.0.0');
}

await bootstrap();
