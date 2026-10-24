/**
 * Разовая перерегистрация состава плана обмена «POS» в 1С (05 §6.2 п. 4; ТЗ для 1С 5.2 п. 7, 6.4; 16 §14.1 шаг 8).
 * Обёртка над `src/cli/onec_reregister.ts` для запуска из исходников без сборки (dev, рабочее место оператора):
 *
 *   npx tsx scripts/onec_reregister.ts --confirm --reason "…" [--journal <путь>]
 *
 * В образе pos-api (каталога `scripts/` и `tsx` там нет) — тот же код из `dist/`:
 *   docker compose run --rm -v /opt/optomstroy/prod/onec-journal:/journal worker \
 *     node dist/cli/onec_reregister.js --confirm --reason "…" --journal /journal/onec_reregister.journal.jsonl
 * Локально после `npm run build`: `npm run onec:reregister -- --confirm --reason "…"`.
 */
import { runReregisterCli } from '../src/cli/onec_reregister.js';

process.exitCode = await runReregisterCli(process.argv.slice(2));
