import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { createApp } from './bootstrap/create-app.js';
import { shutdownOnStdinEof } from './bootstrap/stdin-shutdown.js';
import { type AppConfig, ConfigError, configWarnings, loadAppConfig } from './common/config/app-config.js';

/**
 * Точка входа pos-api (`node dist/main.js`). Конфигурация валидируется до создания приложения: при ошибке —
 * понятное сообщение в stderr (только имена переменных и причины, без значений) и код выхода 1 (RM-C-009 п. 5).
 * Адрес и порт — `API_HOST` / `API_PORT` (по умолчанию 0.0.0.0:3000). Остановка — сигналы (enableShutdownHooks в
 * createApp) или, при `POS_SHUTDOWN_ON_STDIN_EOF=true`, конец stdin (служба Windows): та же последовательность
 * остановки Nest (`app.close` — одна на процесс, сигнал во время неё ждёт её же), затем код выхода 0.
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
  for (const w of configWarnings()) Logger.warn(w, 'Config');
  shutdownOnStdinEof(config.POS_SHUTDOWN_ON_STDIN_EOF, (reason) => {
    Logger.log(`api.shutdown: ${reason} — штатная остановка`, 'Main');
    app.close().then(
      () => process.exit(0),
      (err: unknown) => {
        console.error('pos-api: ошибка штатной остановки по концу stdin', err);
        process.exit(1);
      },
    );
  });
  await app.listen(config.API_PORT, config.API_HOST);
}

await bootstrap();
