import {
  type AccountInfo,
  deliveryStateOfReport,
  type DeliveryReport,
  type DeliveryReportResponse,
  isReportCode,
} from './sms-gateway.js';

/**
 * XML-протокол SMSPro (09 §6.2–§6.6; R2 §3–§5, §13 — дословные выдержки документации). Имена тегов, адреса и
 * коды не изменяются и не дополняются (SMS-004, SRC-B-110): запрос `/api/message` — ровно
 * `message/login, pwd, id, sender, text, phones/phone[, test]` (тег `time` не передаётся — SMS-009).
 *
 * Разбор ответа (SMS-010): решение только по `<status>` (HTTP 200 приходит и при ошибке); парсер
 * namespace-agnostic (`xmlns="http://Giper.mobi/schema/…"` в фактических ответах, в примерах PDF его нет) и
 * терпим к отсутствию необязательных тегов (`<message>`). Внешних зависимостей нет: минимальный безопасный разбор
 * без DTD и внешних сущностей (`<!DOCTYPE` отвергается — защита от XXE и «billion laughs»).
 */

/** Namespace запроса `/api/info` — так в документации (R2 §5.1: «Запрос (с namespace!)»). */
export const SMSPRO_INFO_NS = 'http://Giper.mobi/schema/Info';

const XML_DECL = '<?xml version="1.0" encoding="UTF-8"?>';

export class XmlParseError extends Error {
  override readonly name = 'XmlParseError';
}

/**
 * Есть ли символ, недопустимый в XML 1.0: управляющие (кроме TAB/LF/CR), одиночные суррогаты, U+FFFE/U+FFFF.
 */
function hasInvalidXmlChar(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c < 0x20 && c !== 0x09 && c !== 0x0a && c !== 0x0d) return true;
    if (c === 0xfffe || c === 0xffff) return true;
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = value.charCodeAt(i + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      i += 1;
    } else if (c >= 0xdc00 && c <= 0xdfff) return true;
  }
  return false;
}

/** Экранирование текстового узла XML (SMS-005): `& < > " '`. Недопустимые в XML символы → ошибка (не «чистим» молча). */
export function xmlEscape(value: string): string {
  if (hasInvalidXmlChar(value)) throw new XmlParseError('значение содержит символ, недопустимый в XML 1.0');
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

const el = (name: string, value: string): string => `<${name}>${xmlEscape(value)}</${name}>`;

export interface MessageRequestXml {
  readonly login: string;
  readonly pwd: string;
  readonly id: string;
  readonly sender: string;
  readonly text: string;
  /** `996XXXXXXXXX` без «+», ровно один номер (SMS-008). */
  readonly phone: string;
  readonly test: boolean;
}

/** Тело `POST /api/message` (09 §6.2). Порядок тегов — как в документации и XSD `?xsd=2`. */
export function buildMessageXml(r: MessageRequestXml): string {
  return (
    `${XML_DECL}<message>` +
    el('login', r.login) +
    el('pwd', r.pwd) +
    el('id', r.id) +
    el('sender', r.sender) +
    el('text', r.text) +
    `<phones>${el('phone', r.phone)}</phones>` +
    (r.test ? '<test>1</test>' : '') +
    '</message>'
  );
}

/** Тело `POST /api/dr` (09 §6.5): `phone` передаётся всегда. */
export function buildDrXml(r: { login: string; pwd: string; id: string; phone: string }): string {
  return `${XML_DECL}<dr>${el('login', r.login)}${el('pwd', r.pwd)}${el('id', r.id)}${el('phone', r.phone)}</dr>`;
}

/** Тело `POST /api/info` (09 §6.6) — с namespace, как в документации. */
export function buildInfoXml(r: { login: string; pwd: string }): string {
  return `${XML_DECL}<info xmlns="${SMSPRO_INFO_NS}">${el('login', r.login)}${el('pwd', r.pwd)}</info>`;
}

// ---------------------------------------------------------------------------------------------------------------
// Минимальный разбор XML

export interface XmlElement {
  /** Локальное имя (без префикса namespace). */
  readonly name: string;
  readonly children: XmlElement[];
  /** Конкатенация текстовых узлов и CDATA непосредственно внутри элемента. */
  text: string;
}

export interface ParseXmlOptions {
  readonly maxDepth?: number;
  readonly maxElements?: number;
}

const NAME_RE = /^[A-Za-z_][\w.-]*(?::[A-Za-z_][\w.-]*)?/;
const PREDEFINED: Readonly<Record<string, string>> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };

function decodeEntities(raw: string): string {
  return raw.replace(/&([^;&\s]{1,10});/g, (_m, ent: string) => {
    if (ent.startsWith('#x') || ent.startsWith('#X')) {
      const cp = Number.parseInt(ent.slice(2), 16);
      if (!Number.isFinite(cp) || cp > 0x10ffff) throw new XmlParseError('неверная символьная ссылка');
      return String.fromCodePoint(cp);
    }
    if (ent.startsWith('#')) {
      const cp = Number.parseInt(ent.slice(1), 10);
      if (!Number.isFinite(cp) || cp > 0x10ffff) throw new XmlParseError('неверная символьная ссылка');
      return String.fromCodePoint(cp);
    }
    const v = PREDEFINED[ent];
    if (v === undefined) throw new XmlParseError(`неизвестная сущность &${ent};`);
    return v;
  });
}

const localName = (qname: string): string => qname.slice(qname.indexOf(':') + 1);

/**
 * Разбор документа в дерево элементов. Поддерживаются: декларация, PI, комментарии, CDATA, атрибуты (игнорируются),
 * пустые элементы, предопределённые сущности и символьные ссылки. DOCTYPE/DTD — ошибка.
 */
export function parseXml(input: string, options: ParseXmlOptions = {}): XmlElement {
  const maxDepth = options.maxDepth ?? 32;
  const maxElements = options.maxElements ?? 20_000;
  let s = input.charCodeAt(0) === 0xfeff ? input.slice(1) : input;
  s = s.trimEnd();
  let pos = 0;
  let count = 0;
  let root: XmlElement | undefined;
  const stack: { el: XmlElement; qname: string }[] = [];

  const fail = (msg: string): never => {
    throw new XmlParseError(`${msg} (позиция ${pos})`);
  };

  while (pos < s.length) {
    const lt = s.indexOf('<', pos);
    if (lt === -1) {
      const rest = s.slice(pos);
      if (stack.length > 0) fail('незакрытый элемент');
      if (rest.trim() !== '') fail('текст вне корневого элемента');
      break;
    }
    if (lt > pos) {
      const text = s.slice(pos, lt);
      const top = stack.at(-1);
      if (top) top.el.text += decodeEntities(text);
      else if (text.trim() !== '') fail('текст вне корневого элемента');
    }
    pos = lt;
    if (s.startsWith('<?', pos)) {
      const end = s.indexOf('?>', pos + 2);
      if (end === -1) fail('незакрытая инструкция обработки');
      pos = end + 2;
    } else if (s.startsWith('<!--', pos)) {
      const end = s.indexOf('-->', pos + 4);
      if (end === -1) fail('незакрытый комментарий');
      pos = end + 3;
    } else if (s.startsWith('<![CDATA[', pos)) {
      const end = s.indexOf(']]>', pos + 9);
      if (end === -1) fail('незакрытая секция CDATA');
      const top = stack.at(-1);
      if (!top) fail('CDATA вне корневого элемента');
      else top.el.text += s.slice(pos + 9, end);
      pos = end + 3;
    } else if (s.startsWith('<!', pos)) {
      fail('DOCTYPE/DTD не допускается');
    } else if (s.startsWith('</', pos)) {
      const m = NAME_RE.exec(s.slice(pos + 2));
      if (!m) fail('неверный закрывающий тег');
      const qname = m![0];
      const after = s.indexOf('>', pos + 2 + qname.length);
      if (after === -1 || s.slice(pos + 2 + qname.length, after).trim() !== '') fail('неверный закрывающий тег');
      const top = stack.pop();
      if (!top || top.qname !== qname) fail(`несоответствие закрывающего тега </${qname}>`);
      pos = after + 1;
    } else {
      const m = NAME_RE.exec(s.slice(pos + 1));
      if (!m) fail('неверный открывающий тег');
      const qname = m![0];
      let i = pos + 1 + qname.length;
      // атрибуты: name="..." | name='...'
      let selfClosing = false;
      for (;;) {
        while (i < s.length && /\s/.test(s[i])) i++;
        if (s.startsWith('/>', i)) {
          selfClosing = true;
          i += 2;
          break;
        }
        if (s[i] === '>') {
          i += 1;
          break;
        }
        const an = NAME_RE.exec(s.slice(i));
        if (!an) fail('неверный атрибут');
        i += an![0].length;
        while (i < s.length && /\s/.test(s[i])) i++;
        if (s[i] !== '=') fail('ожидался «=» в атрибуте');
        i++;
        while (i < s.length && /\s/.test(s[i])) i++;
        const q = s[i];
        if (q !== '"' && q !== "'") fail('значение атрибута без кавычек');
        const close = s.indexOf(q, i + 1);
        if (close === -1) fail('незакрытое значение атрибута');
        decodeEntities(s.slice(i + 1, close)); // проверка сущностей
        i = close + 1;
      }
      count += 1;
      if (count > maxElements) fail('слишком много элементов');
      const node: XmlElement = { name: localName(qname), children: [], text: '' };
      const parent = stack.at(-1);
      if (parent) parent.el.children.push(node);
      else if (root) fail('второй корневой элемент');
      else root = node;
      if (!selfClosing) {
        stack.push({ el: node, qname });
        if (stack.length > maxDepth) fail('слишком глубокая вложенность');
      }
      pos = i;
    }
  }
  if (stack.length > 0) fail('незакрытый элемент');
  if (!root) throw new XmlParseError('пустой документ');
  return root;
}

export function child(e: XmlElement, name: string): XmlElement | undefined {
  return e.children.find((c) => c.name === name);
}

export function childrenNamed(e: XmlElement, name: string): XmlElement[] {
  return e.children.filter((c) => c.name === name);
}

/** Текст дочернего элемента (обрезанный); `undefined` — тега нет. */
export function childText(e: XmlElement, name: string): string | undefined {
  const c = child(e, name);
  return c === undefined ? undefined : c.text.trim();
}

/** Целое из текста тега; `undefined` — тега нет или он пуст; не целое → ошибка. */
export function childInt(e: XmlElement, name: string): number | undefined {
  const t = childText(e, name);
  if (t === undefined || t === '') return undefined;
  if (!/^-?\d{1,9}$/.test(t)) throw new XmlParseError(`<${name}>: ожидается целое`);
  return Number(t);
}

function requireInt(e: XmlElement, name: string): number {
  const v = childInt(e, name);
  if (v === undefined) throw new XmlParseError(`нет обязательного тега <${name}>`);
  return v;
}

// ---------------------------------------------------------------------------------------------------------------
// Ответы

export interface MessageResponse {
  readonly id?: string;
  readonly status: number;
  /** Число распознанных номеров (`<phones>`). */
  readonly phones?: number;
  /** Число частей SMS (`<smscnt>`). */
  readonly smscnt?: number;
  /** Необязательное описание ошибки (`<message>`; может отсутствовать). */
  readonly message?: string;
}

/** Разбор ответа `/api/message` (09 §6.3). */
export function parseMessageResponse(xml: string): MessageResponse {
  const root = parseXml(xml);
  const message = childText(root, 'message');
  return {
    id: childText(root, 'id'),
    status: requireInt(root, 'status'),
    phones: childInt(root, 'phones'),
    smscnt: childInt(root, 'smscnt'),
    ...(message ? { message } : {}),
  };
}

/** `YYYYMMDDhhmmss` по времени Бишкека (GMT+6, 09 §6.2) → ISO 8601 UTC; пусто/неверно → `null`. */
export function parseSmsProTime(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(raw.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, se] = m.map(Number) as [number, number, number, number, number, number, number];
  const ms = Date.UTC(y, mo - 1, d, h - 6, mi, se);
  return Number.isNaN(ms) ? null : new Date(ms).toISOString();
}

function parsePhoneReport(p: XmlElement): DeliveryReport | undefined {
  const number = childText(p, 'number') ?? '';
  const report = childInt(p, 'report');
  if (report === undefined || !isReportCode(report)) return undefined;
  return {
    number,
    report,
    sendTime: parseSmsProTime(childText(p, 'sendTime')),
    rcvTime: parseSmsProTime(childText(p, 'rcvTime')),
    state: deliveryStateOfReport(report),
  };
}

/** Разбор ответа `/api/dr` (09 §6.5): `status` и элементы `phone` (при ошибке их нет). */
export function parseDrResponse(xml: string): DeliveryReportResponse {
  const root = parseXml(xml);
  const status = requireInt(root, 'status');
  const reports = childrenNamed(root, 'phone')
    .map(parsePhoneReport)
    .filter((r): r is DeliveryReport => r !== undefined);
  return { status, reports };
}

/** Разбор ответа `/api/info` (09 §6.6). */
export function parseInfoResponse(xml: string): AccountInfo {
  const root = parseXml(xml);
  const status = requireInt(root, 'status');
  const state = childInt(root, 'state');
  const account = childText(root, 'account') ?? '0';
  const smsprice = childText(root, 'smsprice') ?? '0';
  const dec = /^-?\d+(\.\d+)?$/;
  if (!dec.test(account) || !dec.test(smsprice)) throw new XmlParseError('account/smsprice: ожидается десятичное');
  return { status, state: state === 0 ? 0 : 1, account, smsprice };
}

export interface PushReportEntry {
  readonly id: string;
  readonly reports: readonly DeliveryReport[];
}

/** Разбор push-отчёта (09 §6.5): `report/dr[]`, в каждом `id` и `phone[]`. */
export function parseDlrPush(xml: string): PushReportEntry[] {
  const root = parseXml(xml, { maxElements: 50_000 });
  const drs = root.name === 'dr' ? [root] : childrenNamed(root, 'dr');
  const out: PushReportEntry[] = [];
  for (const dr of drs) {
    const id = childText(dr, 'id');
    if (!id) continue;
    out.push({
      id,
      reports: childrenNamed(dr, 'phone')
        .map(parsePhoneReport)
        .filter((r): r is DeliveryReport => r !== undefined),
    });
  }
  return out;
}
