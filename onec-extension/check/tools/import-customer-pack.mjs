// Разовый импорт контракта 1.2.0 и образцов JSON из пакета заказчика (распакованная папка или zip)
// в contract/1.2.0/ и запись MANIFEST.sha256 (sha256 и git blob каждого файла).
// Запуск: node tools/import-customer-pack.mjs <папка_пакета_с_onec-http-service.v1.yaml_и_obrazcy_json>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const DEST = path.join(ROOT, 'contract', '1.2.0');
export const CONTRACT_BLOB = '63995cc4badb60badeda208adec11c8d6a06d864';
export const CONTRACT_SHA256 = 'a4513f1645ebf142caac1dcd23f3d01cd3c3c914c5550ffcf4adc6d862731def';

export function gitBlob(buf) {
  return crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex');
}
export function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function main() {
  const src = process.argv[2];
  if (!src) { console.error('Укажите папку пакета заказчика'); process.exit(2); }
  const yaml = fs.readFileSync(path.join(src, 'onec-http-service.v1.yaml'));
  if (gitBlob(yaml) !== CONTRACT_BLOB || sha256(yaml) !== CONTRACT_SHA256) {
    console.error('Контракт в пакете не совпадает с 1.2.0 (blob/sha256)'); process.exit(1);
  }
  fs.mkdirSync(path.join(DEST, 'obrazcy_json'), { recursive: true });
  fs.writeFileSync(path.join(DEST, 'onec-http-service.v1.yaml'), yaml);
  const lines = [`${sha256(yaml)}  ${gitBlob(yaml)}  onec-http-service.v1.yaml`];
  const names = fs.readdirSync(path.join(src, 'obrazcy_json')).filter((n) => n.endsWith('.json')).sort();
  for (const n of names) {
    const buf = fs.readFileSync(path.join(src, 'obrazcy_json', n));
    fs.writeFileSync(path.join(DEST, 'obrazcy_json', n), buf);
    lines.push(`${sha256(buf)}  ${gitBlob(buf)}  obrazcy_json/${n}`);
  }
  fs.writeFileSync(path.join(DEST, 'MANIFEST.sha256'),
    '# sha256  git-blob  путь — контракт onec-http-service 1.2.0 и образцы JSON из пакета программисту 1С 2026-11-19\n' +
    lines.join('\n') + '\n');
  console.log(`Импортировано: контракт и ${names.length} образцов`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
