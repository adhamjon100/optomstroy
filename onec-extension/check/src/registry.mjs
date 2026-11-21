// Реестр созданных объектов (что найти и как удалить) и изменений плана обмена.
// Запрос, который может создать объект, регистрируется ДО отправки (addPending): если ответа нет (обрыв, таймаут,
// Ctrl+C), объект всё равно попадает в протокол как «результат неизвестен».

const UNKNOWN_HINT = (externalId) => `результат неизвестен — найдите по externalId ${externalId} в регистре POS_ВнешниеИдентификаторыPOS (наименование или комментарий «ПРОВЕРКА POS»)`;

const HOW = {
  Клиент: {
    find: 'Справочник «Партнеры» и «Контрагенты»: наименование начинается с «ПРОВЕРКА POS»; регистр POS_ВнешниеИдентификаторыPOS — запись с этим externalId',
    del: 'Пометьте партнёра и контрагента на удаление и удалите помеченные; запись регистра POS_ВнешниеИдентификаторыPOS удалите вместе с объектом',
  },
  Платеж: {
    find: 'Регистр POS_ВнешниеИдентификаторыPOS — запись с externalId <externalId> (в запросе оплаты комментария нет; по Требованиям §4.7 п. 4 1С пишет в комментарий документа «POS <externalId>»); «Приходный кассовый ордер» или документ из ответа, сумма 1.00 KGS, не проведён',
    del: 'Пометьте документ на удаление и удалите помеченные; запись регистра POS_ВнешниеИдентификаторыPOS удалите вместе с документом',
  },
  Заказ: {
    find: 'Документ «Заказ клиента» с комментарием «POS <externalId> · POS-…-99… · ПРОВЕРКА POS (удалить)»',
    del: 'Пометьте документ на удаление и удалите помеченные; запись регистра POS_ВнешниеИдентификаторыPOS удалите вместе с документом',
  },
  ОплатаQR: {
    find: 'Регистр POS_ОплатыQR — запись с этим externalId (QR на 1.00 KGS, отменён программой)',
    del: 'Удалите запись регистра POS_ОплатыQR и запись POS_ВнешниеИдентификаторыPOS, если она есть',
  },
  Прочее: {
    find: 'По externalId в регистре POS_ВнешниеИдентификаторыPOS',
    del: 'Пометьте объект на удаление и удалите помеченные вместе с записью регистра',
  },
};

/** Вид объекта по операции, которая может его создать. */
export const CREATING_OPS = {
  'POST /pos/v1/customers': 'Клиент',
  'POST /pos/v1/payments': 'Платеж',
  'POST /pos/v1/orders': 'Заказ',
  'POST /pos/v1/payments/qr': 'ОплатаQR',
  'POST /pos/v1/returns': 'ЗаявкаНаВозврат',
};

export class Registry {
  constructor() {
    this.created = [];
    this.exchangePlan = [];
  }

  #find(kind, externalId) {
    return this.created.find((x) => x.externalId === externalId && x.kind === kind) || null;
  }

  #make({ kind, externalId, ref = null, number = null, date = null, checkId, unknown = false, note = null }) {
    const how = HOW[kind] || HOW.Прочее;
    return {
      kind, externalId, ref, number, date, checkId,
      unknown, note,
      find: how.find.replace('<externalId>', externalId),
      how: how.del,
    };
  }

  addCreated({ kind, externalId, ref = null, number = null, date = null, checkId, unknown = false, note = null }) {
    const c = this.#find(kind, externalId);
    if (c) {
      if (ref && !c.ref) Object.assign(c, { ref, number, date, unknown: false, pending: false, note: note ?? (c.pending ? null : c.note) });
      else if (c.pending && !unknown) Object.assign(c, { pending: false, unknown: false, note: note ?? null });
      else if (c.pending && unknown) Object.assign(c, { pending: false, unknown: true, note: note || UNKNOWN_HINT(externalId) });
      // Объект уже создан по ответу (settlePending): пояснение проверки («проведён — отмените проведение») — дописать.
      else if (note && !unknown && !c.unknown) c.note = note;
      return c;
    }
    const rec = this.#make({ kind, externalId, ref, number, date, checkId, unknown, note });
    this.created.push(rec);
    return rec;
  }

  /** Перед запросом, который может создать объект. Несколько запросов с одним externalId — одна запись. */
  addPending({ kind, externalId, checkId }) {
    let c = this.#find(kind, externalId);
    if (!c) {
      c = this.#make({ kind, externalId, checkId, unknown: true, note: 'запрос отправлен, ответа нет' });
      c.pending = true;
      c.everCreated = false;
      this.created.push(c);
    }
    c.inflight = (c.inflight || 0) + 1;
    return c;
  }

  /** Ответ на запрос из addPending: 'created' (2xx), 'rejected' (4xx/5xx с ответом), 'unknown' (нет ответа). */
  settlePending(c, outcome, { ref = null, number = null, date = null } = {}) {
    if (!c) return;
    c.inflight = Math.max(0, (c.inflight || 1) - 1);
    if (outcome === 'created') {
      c.everCreated = true;
      if (ref && !c.ref) Object.assign(c, { ref, number, date });
    } else if (outcome === 'unknown') c.sawUnknown = true;
    if (c.inflight > 0 || !c.pending) {
      if (!c.pending && outcome === 'created' && c.unknown && c.everCreated) Object.assign(c, { unknown: false, note: null });
      return;
    }
    if (c.everCreated) Object.assign(c, { pending: false, unknown: false, note: null });
    else if (c.sawUnknown) Object.assign(c, { pending: false, unknown: true, note: UNKNOWN_HINT(c.externalId) });
    else this.created.splice(this.created.indexOf(c), 1);
  }

  /** Конец прогона (в том числе Ctrl+C): запросы без ответа — «результат неизвестен». */
  finalizePending() {
    for (const c of this.created) {
      if (c.pending) Object.assign(c, { pending: false, unknown: !c.everCreated, note: c.everCreated ? c.note : UNKNOWN_HINT(c.externalId) });
      delete c.inflight; delete c.everCreated; delete c.sawUnknown; delete c.pending;
    }
  }

  /** Запрос, который не должен был ничего создать, ответил 2xx: возможно, создан объект. */
  addSuspect({ checkId, what, ref = null }) {
    const rec = this.#make({ kind: 'Прочее', externalId: '—', ref, checkId, unknown: true, note: `возможно, создан объект: ${what}` });
    this.created.push(rec);
    return rec;
  }

  addPlan({ action, messageNumber = null, checkId, note = null }) {
    this.exchangePlan.push({ action, messageNumber, checkId, note });
  }

  count(kind) {
    return this.created.filter((c) => c.kind === kind).length;
  }
}
