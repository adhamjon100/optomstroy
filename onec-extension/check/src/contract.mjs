// Загрузка контракта 1.2.0 (JSON, собранный из YAML при сборке), таблица операций, разрешение $ref.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

export const PROGRAM_DIR = path.dirname(fileURLToPath(import.meta.url));

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, ''));
}

/** Пути к данным программы: в сборке — рядом (programma/contract, programma/obrazcy), в исходниках — ../contract. */
export function dataPaths(programDir = PROGRAM_DIR) {
  const built = path.join(programDir, 'contract', 'onec-http-service.v1.2.0.json');
  if (fs.existsSync(built)) {
    return {
      mode: 'release',
      contractJson: built,
      meta: path.join(programDir, 'contract', 'meta.json'),
      samples: path.join(programDir, 'obrazcy'),
    };
  }
  const srcRoot = path.resolve(programDir, '..');
  return {
    mode: 'source',
    contractYaml: path.join(srcRoot, 'contract', '1.2.0', 'onec-http-service.v1.yaml'),
    samples: path.join(srcRoot, 'contract', '1.2.0', 'obrazcy_json'),
  };
}

/**
 * Отпечаток программы: sha256 по всем модулям .mjs (путь + содержимое, по алфавиту). Одинаков для src/ и
 * programma/ одной сборки — по нему видно, какой сборкой записан протокол (и что файлы программы не менялись).
 */
export function programHash(programDir = PROGRAM_DIR) {
  const files = [];
  const walk = (dir, rel) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) { if (!['contract', 'obrazcy', 'node_modules'].includes(e.name)) walk(path.join(dir, e.name), rel ? `${rel}/${e.name}` : e.name); }
      else if (e.name.endsWith('.mjs')) files.push([rel ? `${rel}/${e.name}` : e.name, path.join(dir, e.name)]);
    }
  };
  walk(programDir, '');
  files.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
  const h = crypto.createHash('sha256');
  for (const [rel, abs] of files) { h.update(rel + '\0'); h.update(fs.readFileSync(abs)); h.update('\0'); }
  return h.digest('hex');
}

/** Только для запуска из исходников: YAML → объект модулем yaml из pos-api (в сборку не входит). */
function yamlFromSource(yamlPath) {
  const req = createRequire(path.resolve(path.dirname(yamlPath), '../../../../pos-api/package.json'));
  const YAML = req('yaml');
  return YAML.parse(fs.readFileSync(yamlPath, 'utf8'));
}

export function loadContract(programDir = PROGRAM_DIR) {
  const p = dataPaths(programDir);
  let doc, meta;
  if (p.mode === 'release') {
    doc = readJson(p.contractJson);
    meta = readJson(p.meta);
  } else {
    const buf = fs.readFileSync(p.contractYaml);
    doc = yamlFromSource(p.contractYaml);
    meta = {
      version: doc.info.version,
      yamlSha256: crypto.createHash('sha256').update(buf).digest('hex'),
      jsonSha256: null,
      gitBlob: crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex'),
      source: 'исходники (без сборки)',
    };
  }
  meta.programSha256 = programHash(programDir);
  // В сборке отпечаток записан при сборке: если файлы программы с тех пор менялись — видно в --version и протоколе.
  meta.programModified = !!(meta.srcSha256 && meta.srcSha256 !== meta.programSha256);
  return new Contract(doc, meta, p);
}

export class Contract {
  constructor(doc, meta, paths) {
    this.doc = doc;
    this.meta = meta;
    this.paths = paths;
    this.version = doc.info.version;
    this.connectTimeoutMs = doc.info['x-connect-timeout-ms'] ?? 5000;
    // Таймаут вызова без операции контракта (контрольный запрос на несуществующий путь): «прочие вызовы — 30 с»
    // (Требования к API 1С §4.9).
    this.defaultTimeoutMs = 30000;
    // Повтор GET при временной ошибке, как у POS (info.x-get-retry: maxAttempts 3, delaysMs [500, 1000]).
    const gr = doc.info['x-get-retry'];
    this.getRetry = gr && Number.isInteger(gr.maxAttempts) && gr.maxAttempts >= 1
      ? { maxAttempts: gr.maxAttempts, delaysMs: Array.isArray(gr.delaysMs) && gr.delaysMs.length ? gr.delaysMs : [500, 1000] } : null;
    this.ops = new Map();
    for (const [p, item] of Object.entries(doc.paths)) {
      for (const [m, op] of Object.entries(item)) {
        if (!op || typeof op !== 'object' || !op.responses) continue;
        const key = `${m.toUpperCase()} ${p}`;
        const responses = {};
        for (const [st, r0] of Object.entries(op.responses)) {
          const r = r0.$ref ? this.resolve(r0.$ref) : r0;
          const content = r.content || {};
          const json = content['application/json'];
          responses[st] = {
            schema: json ? json.schema : null,
            contentTypes: Object.keys(content),
            headers: Object.keys(r.headers || {}),
          };
        }
        const reqJson = op.requestBody?.content?.['application/json'];
        this.ops.set(key, {
          key, method: m.toUpperCase(), path: p, operationId: op.operationId,
          timeoutMs: op['x-timeout-ms'] ?? 30000,
          errorCodes: op['x-error-codes'] || [],
          status: op['x-status'] || null,
          priority: op['x-priority'] || null,
          responses,
          requestSchema: reqJson ? reqJson.schema : null,
          raw: op,
          regex: new RegExp('^' + p.replace(/\{[^}]+\}/g, '[^/]+') + '$'),
        });
      }
    }
  }

  resolve(ref) {
    if (typeof ref !== 'string' || !ref.startsWith('#/')) throw new Error(`Неизвестная ссылка ${ref}`);
    let cur = this.doc;
    for (const part of ref.slice(2).split('/')) {
      cur = cur?.[part.replace(/~1/g, '/').replace(/~0/g, '~')];
      if (cur === undefined) throw new Error(`Ссылка не найдена: ${ref}`);
    }
    return cur;
  }

  schema(name) {
    return this.doc.components.schemas[name];
  }

  op(key) {
    const o = this.ops.get(key);
    if (!o) throw new Error(`Нет операции в контракте: ${key}`);
    return o;
  }

  /** Операция по методу и фактическому пути (без строки запроса). */
  matchOp(method, pathname) {
    for (const o of this.ops.values()) if (o.method === method && o.regex.test(pathname)) return o;
    return null;
  }

  responseSchema(op, status) {
    const r = op.responses[String(status)];
    return r ? r.schema : null;
  }

  get errorCodes() {
    return this.schema('ErrorCode').enum;
  }

  imageExtensions() {
    return this.op('GET /pos/v1/images/{ref}').raw['x-pos-image-extensions'] || [];
  }

  imageMaxBytes() {
    return this.op('GET /pos/v1/images/{ref}').raw['x-pos-max-source-bytes'] || 10485760;
  }
}
