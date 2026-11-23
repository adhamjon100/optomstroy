// Дополнительные дефекты для тестов (в сборку не входят; включаются фасадом test/helpers/front-1c.mjs, не флагом
// --demo-defect). DX — ОШИБКА у ожидаемой проверки; W — только ЗАМЕЧАНИЕ (код выхода из-за них не 1).
// Каждый: id, что сломано, проверка, русский фрагмент; also — ещё проверки с ошибкой; write — нужна запись
// (--allow-write и подтверждение); exitCode — ожидаемый код.
import crypto from 'node:crypto';
import { IIS_404, IIS_500, IIS_WELCOME, htmlResponse, mutateJson, posError } from './front-1c.mjs';

const isImage = (c) => /^\/pos\/v1\/images\/[^/]+$/.test(c.sub || '');
const isRecv = (c) => /^\/pos\/v1\/customers\/[^/]+\/receivables$/.test(c.sub || '');
const withHeader = (r, k, v) => { const h = { ...r.headers }; if (v === undefined) delete h[k]; else h[k] = v; return { ...r, headers: h }; };

export const EXTRA_PII = { email: 'vymysel.klient@primer-kg.test', inn: '01234567890123' };

export const EXTRA_DEFECTS = [
  {
    id: 'DX01', what: 'у картинки нет ETag', check: 'I1', fragment: 'нет заголовка ETag',
    after: (c, r) => (isImage(c) && r.status === 200 ? withHeader(r, 'etag', undefined) : null),
  },
  {
    id: 'DX02', what: 'нет X-Request-Id ни в одном ответе', check: 'E2', fragment: 'нет заголовка X-Request-Id в ответе',
    after: (c, r) => withHeader(r, 'x-request-id', undefined),
  },
  {
    id: 'DX03', what: 'X-POS-API-Version: 2', check: 'E1', fragment: 'X-POS-API-Version: «2» — нужно 1',
    also: [['H1', 'X-POS-API-Version: «2» — нужно 1']],
    after: (c, r) => (r.headers['x-pos-api-version'] ? withHeader(r, 'x-pos-api-version', '2') : null),
  },
  {
    id: 'DX04', what: '/external-ids: тело 200 — оборванный JSON', check: 'E3', fragment: 'тело — неверный JSON',
    also: [['X1', 'ответ 200 не JSON']],
    after: (c, r) => (c.sub === '/pos/v1/external-ids' && r.status === 200 ? { ...r, body: r.body.subarray(0, Math.floor(r.body.length / 2)) } : null),
  },
  {
    id: 'DX16', what: 'долг клиента: тело 200 — оборванный JSON', check: 'K8', fragment: 'ответ 200 не JSON',
    also: [['E3', 'тело — неверный JSON']],
    after: (c, r) => (isRecv(c) && r.status === 200 ? { ...r, body: r.body.subarray(0, Math.floor(r.body.length / 2)) } : null),
  },
  {
    id: 'DX05', what: 'ошибка данных (/changes с неверным since) — HTML-страница IIS 500', check: 'E11', fragment: 'ошибка данных отдана как 500',
    also: [['C5', 'нужен 400 POS_E_BAD_REQUEST, пришёл 500']],
    after: (c, r) => (c.sub === '/pos/v1/changes' && r.status === 400 ? htmlResponse(500, IIS_500) : null),
  },
  {
    id: 'DX06', what: 'неверный JSON в /payments — HTML-страница IIS 500', check: 'PAY6', fragment: 'ошибка данных отдана как 500', write: true,
    also: [['E11', 'ошибка данных отдана как 500']],
    before: (c) => (c.method === 'POST' && c.sub === '/pos/v1/payments' && c.key && !c.json().ok ? htmlResponse(500, IIS_500) : null),
  },
  {
    id: 'DX07', what: 'несуществующая картинка — HTML-страница IIS 404 вместо тела POS', check: 'I3', fragment: 'без тела ошибки в едином формате',
    after: (c, r) => (isImage(c) && r.status === 404 ? htmlResponse(404, IIS_404) : null),
  },
  {
    id: 'DX08', what: 'тело ошибки без code', check: 'E7', fragment: 'тело ошибки не по формату',
    also: [['K9', 'без тела ошибки в едином формате']],
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { delete j.code; }) : null),
  },
  {
    id: 'DX09', what: 'ошибка 400 с Content-Type: text/plain', check: 'E3', fragment: 'ответ не JSON (Content-Type: text/plain',
    after: (c, r) => (c.sub === '/pos/v1/changes' && r.status === 400 ? withHeader(r, 'content-type', 'text/plain; charset=utf-8') : null),
  },
  {
    id: 'DX10', what: 'charset=windows-1251 в заголовке при теле UTF-8', check: 'E3', fragment: 'charset=windows-1251 — нужно utf-8',
    after: (c, r) => (c.sub === '/pos/v1/health' && r.status === 200 ? withHeader(r, 'content-type', 'application/json; charset=windows-1251') : null),
  },
  {
    id: 'DX11', what: 'лишнее значение перечня: kind = "company"', check: 'K7', fragment: 'не из перечня контракта',
    after: (c, r) => (c.method === 'GET' && c.sub === '/pos/v1/customers' && r.status === 200 ? mutateJson(r, (j) => { for (const x of j) x.kind = 'company'; }) : null),
  },
  {
    id: 'DX12', what: 'повтор оплаты создаёт второй документ (201, новый ref)', check: 'PAY2', fragment: 'повтор создал второй документ', write: true,
    after: (c, r) => {
      if (!(c.method === 'POST' && c.sub === '/pos/v1/payments' && r.status === 200)) return null;
      return { ...mutateJson(r, (j) => { j.ref = crypto.randomUUID(); j.number = 'ПКО0-9' + String(crypto.randomInt(0, 1e5)).padStart(5, '0'); }), status: 201 };
    },
  },
  {
    id: 'DX13', what: 'e-mail и ИНН клиента в тексте ошибки', check: 'E9', fragment: 'в тексте ошибки e-mail',
    also: [['E9', 'в тексте ошибки ИНН']], pii: [EXTRA_PII.email, EXTRA_PII.inn],
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { j.message = `Клиент ${EXTRA_PII.email} (ИНН ${EXTRA_PII.inn}) не найден`; }) : null),
  },
  {
    id: 'DX14', what: 'имя клиента в тексте ошибки 409', check: 'E9', fragment: 'в тексте ошибки имя клиента', write: true,
    after: (c, r) => (c.method === 'POST' && c.sub === '/pos/v1/customers' && r.status === 409 ? mutateJson(r, (j) => { j.message = 'Найден клиент ООО Пример с тем же телефоном'; }) : null),
  },
  {
    id: 'DX15', what: '/health — стартовая страница IIS (200, HTML)', check: 'A1', fragment: 'ответ 200 без JSON', exitCode: 2,
    also: [['E3', 'ответ не JSON']],
    before: (c) => (c.sub === '/pos/v1/health' && c.key && c.auth.startsWith('Basic ') ? htmlResponse(200, IIS_WELCOME) : null),
  },
  // fix2: сумма долга в тексте ошибки в формате 1С (пробел, неразрывный пробел и запятая, меньше 1000) — V13, V13c, V13d.
  {
    id: 'DX25', what: 'сумма долга в тексте ошибки: «сумма долга 15 300.00 сом»', check: 'E9', fragment: 'в тексте ошибки сумма долга',
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { j.message = 'Клиент не найден, сумма долга 15 300.00 сом не обновлена'; }) : null),
  },
  {
    id: 'DX26', what: 'сумма долга по Формату 1С: «долг 15\u00a0300,00 сом»', check: 'E9', fragment: 'в тексте ошибки сумма долга',
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { j.message = 'Клиент не найден, долг 15\u00a0300,00 сом'; }) : null),
  },
  {
    id: 'DX27', what: 'небольшая сумма долга: «задолженность 850.00 сом»', check: 'E9', fragment: 'в тексте ошибки сумма долга',
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { j.message = 'Клиент не найден, задолженность 850.00 сом'; }) : null),
  },
  // fix2: ФИО клиента без слова «клиент» (V35) — ОШИБКА E9, в протоколе (консоль, .html, .md, .json) имени нет.
  {
    id: 'DX28', what: 'ФИО клиента в тексте ошибки без слова «клиент»', check: 'E9', fragment: 'в тексте ошибки имя клиента', pii: ['Асанов', 'Бакыт', 'Жумабекович'],
    after: (c, r) => (isRecv(c) && r.status === 404 ? mutateJson(r, (j) => { j.message = 'Асанов Бакыт Жумабекович: карточка не найдена'; }) : null),
  },
  // fix2: Новый УникальныйИдентификатор() вместо ссылки — ref товара новый при каждом чтении того же сообщения (V60b).
  {
    id: 'DX29', what: 'ref товара новый при каждом чтении /changes (Новый УникальныйИдентификатор)', check: 'C1', fragment: 'ссылка объекта меняется от чтения к чтению',
    after: (c, r) => (c.method === 'GET' && c.sub === '/pos/v1/changes' && r.status === 200
      ? mutateJson(r, (j) => { for (const it of j.items || []) if (it.type === 'Catalog_Номенклатура') it.ref = crypto.randomUUID(); }) : null),
  },
].map((d) => ({ verdict: 'FAIL', exitCode: 1, ...d }));

// Только ЗАМЕЧАНИЕ: программа сообщает, но код выхода из-за них не 1 (exitCode null — другие проверки тоже падают).
const UNKNOWN_TYPE_ITEM = { type: 'Catalog_ВымышленныйСправочник', ref: '9a8b7c6d-0000-4000-8000-0000000000f1', dataVersion: 'AAAAAQAAAAE=', deletionMark: false };
const lastChangesPage = (c, r) => c.method === 'GET' && c.sub === '/pos/v1/changes' && r.status === 200;

export const WARN_DEFECTS = [
  {
    id: 'W01', what: 'перерегистрация отвечает 204 вместо 202', check: 'C6', fragment: 'по контракту 202 Accepted', write: true, rereg: true, exitCode: 0,
    after: (c, r) => (c.sub === '/pos/v1/changes/reregister' && r.status === 202 ? { ...r, status: 204 } : null),
  },
  {
    id: 'W02', what: 'Content-Type без charset', check: 'E3', fragment: 'нет charset=utf-8', exitCode: 0,
    after: (c, r) => (/^application\/json/.test(String(r.headers['content-type'] || '')) ? withHeader(r, 'content-type', 'application/json') : null),
  },
  {
    id: 'W03', what: 'exchangeNode не POS', check: 'H1', fragment: 'exchangeNode = «УТ_POS»', exitCode: 0,
    after: (c, r) => (c.sub === '/pos/v1/health' && r.status === 200 ? mutateJson(r, (j) => { j.exchangeNode = 'УТ_POS'; }) : null),
  },
  {
    id: 'W04', what: 'код ошибки не из x-error-codes метода (503 POS_E_LOCKED у /receivables)', check: 'E7', fragment: 'не указан в x-error-codes метода GET /pos/v1/customers/{ref}/receivables', exitCode: null,
    after: (c, r) => (isRecv(c) && r.status === 404 ? posError(503, 'POS_E_LOCKED', 'Данные клиента заблокированы, повторите позже', c.reqId) : null),
  },
  {
    id: 'W05', what: 'неизвестный тип элемента /changes', check: 'C3', fragment: 'неизвестный тип элемента', exitCode: 0,
    after: (c, r) => (lastChangesPage(c, r) ? mutateJson(r, (j) => { if (j.hasMore === false && j.items.length) j.items.push({ ...UNKNOWN_TYPE_ITEM }); }) : null),
  },
  {
    id: 'W06', what: 'поле-опечатка isFoldr у товара', check: 'C3', fragment: 'возможно, опечатка', exitCode: 0,
    after: (c, r) => (lastChangesPage(c, r) ? mutateJson(r, (j) => { for (const it of j.items) if (it.type === 'Catalog_Номенклатура') it.isFoldr = false; }) : null),
  },
].map((d) => ({ verdict: 'WARN', ...d }));

// ПДн для проверки маски: контрагент с ИНН и партнёр с ФИО и телефоном — в последней странице сообщения.
export const RICH_PII = {
  names: ['ООО Вымышленная Ромашка', 'Вымышленный Иван Петрович', 'ИП Вымышленный Иван Петрович'],
  inn: '02345678901234',
  phones: ['+996555123456', '0555 12 34 56'],
};
export const RICH_PII_HOOK = {
  id: 'PII', what: 'в /changes контрагент с ИНН и партнёр с ФИО и телефоном',
  after: (c, r) => (lastChangesPage(c, r) ? mutateJson(r, (j) => {
    if (!(j.hasMore === false && j.items.length)) return;
    j.items.push({
      type: 'Catalog_Партнеры', ref: '9a8b7c6d-0000-4000-8000-0000000000f2', dataVersion: 'AAAAAQAAAAI=', deletionMark: false,
      externalId: null, code: 'ПР-990001', description: RICH_PII.names[1], fullName: RICH_PII.names[2], isClient: true, mainAgreementRef: null,
      phones: [{ phone: RICH_PII.phones[0], presentation: RICH_PII.phones[1] }],
    });
    j.items.push({
      type: 'Catalog_Контрагенты', ref: '9a8b7c6d-0000-4000-8000-0000000000f3', dataVersion: 'AAAAAQAAAAM=', deletionMark: false,
      code: 'К-990001', description: RICH_PII.names[0], partnerRef: '9a8b7c6d-0000-4000-8000-0000000000f2', taxId: RICH_PII.inn,
    });
  }) : null),
};
