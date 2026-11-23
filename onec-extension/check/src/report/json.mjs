// Запись трёх файлов протокола (HTML, Markdown, JSON). Имена — ASCII; весь текст — через вычистку секретов.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { renderHtml } from './html.mjs';
import { renderMarkdown } from './markdown.mjs';
import { fileStamp } from './time.mjs';

export function renderJson(m) {
  return JSON.stringify(m, null, 2) + '\n';
}

function writable(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true });
    const probe = path.join(dir, `.proverka_${process.pid}.tmp`);
    fs.writeFileSync(probe, 'x');
    fs.unlinkSync(probe);
    return true;
  } catch {
    return false;
  }
}

/** @returns {{dir:string, files:string[], fallback:boolean}} */
export function writeProtocol(model, { outDir, redactor, demo = false, startedAt }) {
  let dir = outDir;
  let fallback = false;
  if (!writable(dir)) {
    dir = path.join(os.homedir(), 'Proverka_API_1C_protokoly');
    fallback = true;
    fs.mkdirSync(dir, { recursive: true });
  }
  let base = `protokol_proverki_API_1C_${demo ? 'DEMO_' : ''}${fileStamp(startedAt)}`;
  let n = 1;
  while (['.html', '.md', '.json'].some((e) => fs.existsSync(path.join(dir, base + (n > 1 ? `_${n}` : '') + e)))) n++;
  if (n > 1) base += `_${n}`;
  const out = [];
  const put = (ext, text) => {
    const f = path.join(dir, base + ext);
    fs.writeFileSync(f, redactor.redact(text), 'utf8');
    out.push(f);
  };
  put('.html', renderHtml(model));
  put('.md', renderMarkdown(model));
  put('.json', renderJson(model));
  return { dir, files: out, fallback };
}
