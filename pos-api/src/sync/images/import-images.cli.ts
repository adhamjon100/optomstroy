import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import pg from 'pg';
import pino from 'pino';
import { loadAppConfig } from '../../common/config/app-config.js';
import { createRunTracker } from '../apply/run-tracker.js';
import { type DirectoryLayout, ImageDirectoryImporter } from './image-directory-import.js';
import { ImageStore } from './image-store.js';

/**
 * Разовый импорт фото из каталога выгрузки (05 SYNC-036; RM-E-003, фаза 0 без HS расширения):
 *
 *   node dist/sync/images/import-images.cli.js --dir /data/import/cml [--layout auto|commerceml|by-name]
 *   npx tsx src/sync/images/import-images.cli.ts --dir D:/export --media-dir D:/media   (разработка)
 *
 * Конфигурация — как у pos-worker (`DATABASE_URL_FILE`, `MEDIA_DIR`, 16 §4.3); `--media-dir` переопределяет
 * `MEDIA_DIR`. Прогон пишется в `sync_runs` (entity `images`, mode `full`, trigger `manual`).
 * Коды выхода: 0 — без ошибок позиций; 1 — есть ошибки позиций (`sync_errors`); 2 — ошибка параметров/конфигурации.
 */
export async function main(argv = process.argv.slice(2), env: NodeJS.ProcessEnv = process.env): Promise<number> {
  let values: { dir?: string; layout?: string; 'media-dir'?: string };
  try {
    ({ values } = parseArgs({
      args: argv,
      options: { dir: { type: 'string' }, layout: { type: 'string' }, 'media-dir': { type: 'string' } },
      strict: true,
    }));
  } catch (e) {
    process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
  const layout = (values.layout ?? 'auto') as DirectoryLayout;
  if (!values.dir || !['auto', 'commerceml', 'by-name'].includes(layout)) {
    process.stderr.write(
      'Использование: import-images --dir <каталог> [--layout auto|commerceml|by-name] [--media-dir <путь>]\n',
    );
    return 2;
  }
  let config;
  try {
    config = loadAppConfig(env);
  } catch (e) {
    process.stderr.write(`Конфигурация: ${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
  if (!config.DATABASE_URL) {
    process.stderr.write('Конфигурация: DATABASE_URL_FILE не задан\n');
    return 2;
  }
  const log = pino({ level: config.LOG_LEVEL }).child({ component: 'sync.images.import' });
  const pool = new pg.Pool({ connectionString: config.DATABASE_URL, max: 3 });
  try {
    const importer = new ImageDirectoryImporter(
      pool,
      new ImageStore(values['media-dir'] ?? config.MEDIA_DIR),
      createRunTracker(pool),
      log,
    );
    const r = await importer.run({ dir: values.dir, layout, trigger: 'manual' });
    process.stdout.write(
      `${JSON.stringify({ runId: r.runId, status: r.status, layout: r.layout, counts: r.counts })}\n`,
    );
    return r.counts.errors > 0 ? 1 : 0;
  } finally {
    await pool.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
      process.exit(2);
    },
  );
}
