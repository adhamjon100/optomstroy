// Секреты: пароль, JWT, ключ клиента. Только скрытый ввод или файлы по путям из настроек.
// Программа их на диск не пишет и не выводит; каждый секрет регистрируется для вычистки.
// В сообщениях об ошибках введённое не повторяется: в поле пути по ошибке может оказаться сам пароль.
import fs from 'node:fs';
import path from 'node:path';
import { decodeTextFile, stripQuotes } from './util.mjs';

export class SettingsError extends Error {
  constructor(msg) { super(msg); this.code = 'SETTINGS'; }
}

const WHAT_RU = { passwordFile: 'с паролем', clientKeyFile: 'с ключом клиента', tokenFile: 'с JWT' };

/** Путь показывается, только если он похож на путь (есть \ или / и расширение) — иначе это может быть сам секрет. */
function shownPath(raw) {
  const s = String(raw ?? '');
  return /[\\/]/.test(s) && /\.[A-Za-z0-9]{1,5}$/.test(s) ? ` (${s})` : '';
}

/**
 * Файл секрета: одна строка, UTF-8 или UTF-16 (Блокнот «Юникод»); BOM и конечный перевод строки снимаются.
 * @param {string} file — полный путь
 * @param {string} key — ключ настроек (passwordFile, clientKeyFile, tokenFile)
 * @param {string} raw — значение из настроек как есть (для сообщения)
 */
export function readSecretFile(file, key, raw = file) {
  const what = WHAT_RU[key] || 'секрета';
  let buf;
  try { buf = fs.readFileSync(file); } catch (e) {
    const code = e && e.code ? e.code : 'ошибка чтения';
    const why = code === 'ENOENT' ? 'не найден' : code === 'EISDIR' ? '— это папка, а не файл' : `не прочитан (${code})`;
    throw new SettingsError(`файл, указанный в ${key}${shownPath(raw)}, ${why} — там должен быть ПУТЬ к файлу ${what}, а не сам секрет`);
  }
  let text = decodeTextFile(buf);
  text = text.replace(/(\r?\n)+$/, '');
  if (/[\r\n]/.test(text)) throw new SettingsError(`в файле ${key} больше одной строки — нужна ровно одна строка`);
  if (!text) throw new SettingsError(`файл ${key} пустой`);
  return text;
}

export function checkSecretValue(value, what) {
  if (value == null || value === '') throw new SettingsError(`${what} не введён`);
  if (/[\r\n]/.test(value)) throw new SettingsError(`${what} содержит перевод строки`);
  return value;
}

/**
 * Ключ клиента и JWT уходят в заголовок как есть: допустимы только латиница, цифры и знаки (0x21–0x7E).
 * Русские буквы обычно значат, что ключ набран в русской раскладке.
 */
export function checkHeaderSecret(value, what) {
  if (/[^\x21-\x7e]/.test(value)) {
    throw new SettingsError(`в ${what} есть русские буквы, пробелы или другие недопустимые символы — проверьте раскладку клавиатуры (нужны латиница, цифры и знаки)`);
  }
  return value;
}

/**
 * Получить секреты: из файлов (пути в настройках, относительно папки настроек) или скрытым вводом.
 * @returns {{password?:string, token?:string, clientKey:string, sources:object, warnings:string[]}}
 */
export async function obtainSecrets(settings, prompter, baseDir) {
  const res = { sources: {}, warnings: [] };
  const abs = (p) => { const q = stripQuotes(p); return path.isAbsolute(q) ? q : path.join(baseDir, q); };
  if (settings.auth === 'bearer') {
    if (settings.tokenFile) { res.token = readSecretFile(abs(settings.tokenFile), 'tokenFile', settings.tokenFile); res.sources.token = 'файл'; }
    else {
      const t = await prompter.hidden('JWT пользователя (ввод скрыт): ');
      res.token = checkSecretValue(t, 'JWT');
      res.sources.token = 'ввод';
    }
    checkHeaderSecret(res.token, 'JWT');
  } else {
    if (settings.passwordFile) { res.password = readSecretFile(abs(settings.passwordFile), 'passwordFile', settings.passwordFile); res.sources.password = 'файл'; }
    else {
      const p = await prompter.hidden(`Пароль пользователя ${settings.user} (ввод скрыт): `);
      res.password = checkSecretValue(p, 'пароль');
      res.sources.password = 'ввод';
    }
    // eslint-disable-next-line no-control-regex
    if (/[^\x20-\x7e]/.test(res.password)) {
      res.warnings.push('в пароле есть символы не из латиницы — как платформа 1С разберёт такой пароль в Basic, заранее неизвестно');
    }
  }
  if (settings.clientKeyFile) { res.clientKey = readSecretFile(abs(settings.clientKeyFile), 'clientKeyFile', settings.clientKeyFile); res.sources.clientKey = 'файл'; }
  else {
    const k = await prompter.hidden('Ключ клиента X-POS-Client-Key (ввод скрыт): ');
    res.clientKey = checkSecretValue(k, 'ключ клиента');
    res.sources.clientKey = 'ввод';
  }
  checkHeaderSecret(res.clientKey, 'ключе клиента');
  return res;
}
