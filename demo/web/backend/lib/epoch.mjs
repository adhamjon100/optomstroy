// Ключ эпохи веб-демо (WP-B3, critic [15]): хэш того, от чего зависят данные в браузере зрителя, а не id сборки.
// Новая выкладка с тем же ключом сохраняет данные заказчика (настоящий мигратор на тёплом старте применяет новые
// миграции); другой ключ — страница предупреждает и начинает демо заново (WP-S1).
//
// В ключ входят:
//  - миграции pos-api до EPOCH_MIGRATION_BASE включительно (имя + sha256): изменить применённую миграцию нельзя
//    (мигратор forward-only, MIGRATION_CHECKSUM_MISMATCH), более поздние — применяются к существующим данным;
//  - dev-миграции и seeds целиком (меняются редко; их изменение без новой эпохи сломало бы мигратор);
//  - генераторы данных, которые воркер пересоздаёт на каждом холодном старте и которые должны совпасть с уже
//    сохранёнными данными: синтетический каталог, синтетика кассира (с заменой ПДн pii-map.json), план обмена,
//    имитатор 1С (scripts/pos_fake_onec.ts), параметры DEMO_DATA (число SKU, seed, клиенты);
//  - из манифеста снимка БД (WP-B4, .build/snapshot/manifest.json), если он есть, — блок `epoch`: привязка фото
//    «товар → sha», параметры каталога, сотрудники, формат (не схема и не строки: их меняют и поздние миграции);
//  - версия формата demo_meta (DEMO_DATA.stateFormat).
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { DEMO_DATA, EPOCH_MIGRATION_BASE } from '../demo-config.mjs';
import { API, BACKEND, BUILD, DIST, SCRIPTS } from './paths.mjs';

const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const files = (dir, re) => (existsSync(dir) ? readdirSync(dir).filter((f) => re.test(f)).sort() : []);

/** Генераторы данных (dist после tsc), которые воркер пересоздаёт на каждом старте. */
export const EPOCH_GENERATORS = [
  'integrations/onec/synthetic-catalog.js',
  'integrations/onec/synthetic-cashier.js',
  'integrations/onec/fake-exchange-plan.js',
  'integrations/onec/fake-onec.gateway.js',
];

export function computeEpoch() {
  const inputs = { migrationBase: EPOCH_MIGRATION_BASE, migrations: [], laterMigrations: [], devMigrations: [], seeds: [], generators: {}, data: DEMO_DATA, snapshot: null };
  for (const f of files(`${API}/migrations`, /^\d{4}_.*\.sql$/)) {
    const entry = [f, sha256(readFileSync(`${API}/migrations/${f}`))];
    if (f.slice(0, 4) <= EPOCH_MIGRATION_BASE) inputs.migrations.push(entry);
    else inputs.laterMigrations.push(f);
  }
  for (const f of files(`${API}/db/migrations-dev`, /\.sql$/)) inputs.devMigrations.push([f, sha256(readFileSync(`${API}/db/migrations-dev/${f}`))]);
  for (const f of files(`${API}/seeds`, /\.(sql|json)$/)) inputs.seeds.push([f, sha256(readFileSync(`${API}/seeds/${f}`))]);
  for (const rel of EPOCH_GENERATORS) {
    const p = `${DIST}/${rel}`;
    if (!existsSync(p)) throw new Error(`epoch: нет ${p} (сначала tsc)`);
    inputs.generators[rel] = sha256(readFileSync(p));
  }
  inputs.generators['scripts/pos_fake_onec.ts'] = sha256(readFileSync(`${SCRIPTS}/pos_fake_onec.ts`));
  inputs.generators['backend/pii-map.json'] = sha256(readFileSync(`${BACKEND}/pii-map.json`));
  const manifest = `${BUILD}/snapshot/manifest.json`;
  if (existsSync(manifest)) {
    const m = JSON.parse(readFileSync(manifest, 'utf8'));
    delete m.builtAt;
    delete m.generatedAt;
    inputs.snapshot = sha256(JSON.stringify(m.epoch ?? m));
  }
  const { laterMigrations, ...keyed } = inputs;
  const key = `e${sha256(JSON.stringify(keyed)).slice(0, 15)}`;
  return { key, inputs: { ...inputs, laterMigrations } };
}

/** Версия pos-app (pubspec.yaml `version:`) — для MIN_APP_VERSION (critic [3]). */
export function readAppVersion(pubspecPath) {
  const m = /^version:\s*([^\s#]+)/m.exec(readFileSync(pubspecPath, 'utf8'));
  if (!m) throw new Error(`нет version: в ${pubspecPath}`);
  return m[1];
}
