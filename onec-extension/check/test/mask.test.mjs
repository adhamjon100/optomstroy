// Маскирование ПДн (§3.4) и вычистка секретов (§2.5): телефоны всех видов, ИНН, e-mail, адреса, имена клиентов и
// контактных лиц, свободный текст; товары, коды, суммы, GUID, даты и «ПРОВЕРКА POS» остаются.
// Данные вымышленные.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import util from 'node:util';
import { Masker, Redactor, maskPhone, maskQueryPhone, kindOfKey, MASK_NAME, MASK_ADDRESS, MASK_INN, MASK_TEXT } from '../src/mask.mjs';

test('телефоны: +996, 996, 00996, 0XXXXXXXXX, со скобками, пробелами и дефисами, чужие E.164', () => {
  const m = new Masker();
  const cases = ['+996555123456', '996555123456', '00996555123456', '0555123456', '0555 12 34 56', '+996 (555) 12-34-56', '+7 900 123-45-67'];
  for (const c of cases) {
    const s = m.maskText(`звонить ${c} вечером`);
    assert.ok(!s.includes(c), `${c} → ${s}`);
    assert.ok(!/123456|12-34|12 34|123-45/.test(s), s);
    assert.match(s, /\*\*\* \*\* \d\d/);
  }
  assert.equal(maskPhone('+7 900 123-45-67'), '+*** *** ** 67');
  assert.equal(maskPhone('0555 12 34 56'), '+996 *** ** 56');
  assert.equal(maskQueryPhone('/pos/v1/customers?phone=0555123456&limit=1'), '/pos/v1/customers?phone=[+996 *** ** 56]&limit=1');
});

test('ИНН (14 цифр) и e-mail скрываются; номера документов, коды, суммы, GUID и даты — нет', () => {
  const m = new Masker();
  const s = m.maskText('ИНН 02345678901234, почта vymysel@primer-kg.test; РТУ00-000123 от 2026-11-19T10:00:00+06:00 на 16007.50, ref a1b2c3d4-0000-4000-8000-000000000001, код 00004521, штрихкод 4601234567890');
  assert.ok(!s.includes('02345678901234') && !s.includes('vymysel@'));
  assert.ok(s.includes('[ИНН скрыт]') && s.includes('[e-mail скрыт]'));
  for (const keep of ['РТУ00-000123', '2026-11-19T10:00:00+06:00', '16007.50', 'a1b2c3d4-0000-4000-8000-000000000001', '00004521', '4601234567890']) assert.ok(s.includes(keep), keep);
});

test('по схеме: адрес, получатель, телефон получателя, контактное лицо, курьеру — скрыты', () => {
  const m = new Masker();
  const j = m.maskJson({
    delivery: { method: 'delivery', address: 'г. Бишкек, ул. Вымышленная, 1', receiverName: 'Вымышленный Получатель', receiverPhone: '+996555000111', courierComment: 'позвонить за час' },
    contactPerson: 'Вымышленная Контактная', contactName: 'Вымышленный Контакт',
  });
  assert.equal(j.delivery.address, MASK_ADDRESS);
  assert.equal(j.delivery.receiverName, MASK_NAME);
  assert.equal(j.delivery.receiverPhone, '+996 *** ** 11');
  assert.equal(j.delivery.courierComment, MASK_TEXT);
  assert.equal(j.delivery.method, 'delivery');
  assert.equal(j.contactPerson, MASK_NAME);
  assert.equal(j.contactName, MASK_NAME);
});

test('контрагент: имя и ИНН скрыты; товар, упаковка и склад — видны', () => {
  const m = new Masker();
  const j = m.maskJson({
    items: [
      { type: 'Catalog_Контрагенты', ref: 'a1b2c3d4-0000-4000-8000-0000000000f3', description: 'ООО Вымышленная Ромашка', taxId: '02345678901234' },
      { type: 'Catalog_Номенклатура', ref: 'a1b2c3d4-0000-4000-8000-000000000001', description: 'Смеситель для кухни', fullName: 'Смеситель для кухни однорычажный' },
      { type: 'Catalog_УпаковкиЕдиницыИзмерения', description: 'Коробка (6 шт)' },
      { type: 'Catalog_Склады', description: 'Основной склад' },
    ],
  });
  assert.equal(j.items[0].description, MASK_NAME);
  assert.equal(j.items[0].taxId, MASK_INN);
  assert.equal(j.items[1].description, 'Смеситель для кухни');
  assert.equal(j.items[1].fullName, 'Смеситель для кухни однорычажный');
  assert.equal(j.items[2].description, 'Коробка (6 шт)');
  assert.equal(j.items[3].description, 'Основной склад');
  // Увиденное имя скрывается и в свободном тексте (например, в message ошибки).
  assert.equal(m.maskText('Клиент ООО Вымышленная Ромашка заблокирован'), `Клиент ${MASK_NAME} заблокирован`);
  assert.deepEqual(m.findPii('Клиент ООО Вымышленная Ромашка заблокирован'), ['имя клиента']);
});

test('комментарий документа: префикс POS остаётся, свободный текст скрыт; «ПРОВЕРКА POS» — виден', () => {
  const m = new Masker();
  const j = m.maskJson({
    a: { comment: 'POS 0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a90 · POS-2026-000124 · позвонить Вымышленному' },
    b: { comment: 'POS 0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a90 · POS-2026-990001 · ПРОВЕРКА POS (удалить)' },
    c: { externalId: '5e1f7e57-0000-4000-8000-000000000001', name: 'ПРОВЕРКА POS клиент 101010 (удалить)', phone: '+996000123456', dedupe: {} },
  });
  assert.equal(j.a.comment, `POS 0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a90 · POS-2026-000124 · ${MASK_TEXT}`);
  assert.ok(j.b.comment.endsWith('ПРОВЕРКА POS (удалить)'));
  assert.equal(j.c.name, 'ПРОВЕРКА POS клиент 101010 (удалить)');
  assert.equal(j.c.phone, '+996 *** ** 56');
});

test('проба нового метода (неизвестная структура): строки с буквами и пробелами скрыты, коды и GUID — нет', () => {
  const m = new Masker();
  const j = m.maskJson({ items: [{ customerRef: 'c3d4e5f6-0000-4000-8000-0000000000dd', customerTitle: 'Вымышленный Клиент Иванович', documentType: 'Реализация', number: 'РТУ00-000001', balance: '1500.00', note: 'Вымышленная заметка о клиенте' }] }, { mode: 'unknown' });
  const it = j.items[0];
  assert.ok([MASK_TEXT, MASK_NAME].includes(it.customerTitle), it.customerTitle);
  assert.equal(it.note, MASK_TEXT);
  assert.equal(it.customerRef, 'c3d4e5f6-0000-4000-8000-0000000000dd');
  assert.equal(it.documentType, 'Реализация');
  assert.equal(it.number, 'РТУ00-000001');
  assert.equal(it.balance, '1500.00');
});

test('E9: что считается ПДн в тексте ошибки', () => {
  const m = new Masker();
  assert.deepEqual(m.findPii('Клиент с телефоном 0555 12 34 56 уже есть'), ['телефон']);
  assert.deepEqual(m.findPii('ИНН 02345678901234 занят'), ['ИНН']);
  assert.deepEqual(m.findPii('Напишите на vymysel@primer-kg.test'), ['e-mail']);
  assert.deepEqual(m.findPii('Документ a1b2c3d4-0000-4000-8000-000000000001 от 2026-11-19T10:00:00+06:00 не найден'), []);
  assert.deepEqual(m.findPii('Заказ не найден'), []);
});

test('приватность: телефоны 0XXX-XX-XX-XX и 9 цифр, адреса и имена в полях любых имён, проба — каждое слово', () => {
  const m = new Masker();
  for (const c of ['тел 0555-12-34-56', '555 12 34 56', '(555) 123-456', '700 123 456', '0700-123-456', 'тел.0555123456', '2026-11-20 0555-12-34-56']) {
    const s = m.maskText(c);
    assert.match(s, /\+996 \*\*\* \*\* \d\d/, `${c} → ${s}`);
    assert.ok(!/555|700 123|123-456/.test(s.replace('2026-11-20', '')), `${c} → ${s}`);
    assert.deepEqual(m.findPii(c), ['телефон'], c);
  }
  assert.ok(m.maskText('2026-11-20 0555-12-34-56').startsWith('2026-11-20 '), 'настоящая дата остаётся');
  // имя после «клиент» — скрыто, даже если в /changes его не было
  assert.equal(m.maskText('Клиент Жумабеков уже есть'), `Клиент ${MASK_NAME} уже есть`);
  assert.equal(m.maskText('ОсОО «Ромашка-Тест» должен'), `${MASK_NAME} должен`);
  // поля, которых нет в контракте 1.2.0: адреса, контакты, директор
  const j = m.maskJson({ type: 'Catalog_Партнеры', description: 'Вымышленный Иван', legalAddress: 'г. Бишкек, ул. Вымышленная, 77',
    addresses: ['г. Ош, ул. Вымышленная, 1'], contacts: [{ kind: 'phone', value: '0777-11-22-33' }, { kind: 'email', value: 'x@primer-kg.test' }],
    director: 'Вымышленный Директор', contactPerson: 'Вымышленная Контактная', inn: '02345678901234' });
  const sj = JSON.stringify(j);
  for (const bad of ['Вымышленная, 77', 'Ош', '0777', 'primer-kg', 'Директор', 'Контактная', '02345678901234']) assert.ok(!sj.includes(bad), `${bad}: ${sj}`);
  assert.equal(j.legalAddress, MASK_ADDRESS);
  assert.equal(j.contacts[0].value, '+996 *** ** 33');
  // проба: одно слово и строка с GUID — тоже скрыты; чистые GUID и дата — нет
  const u = m.maskJson({ items: [{ customerName: 'Асанова', note: 'Иванов 5e1f7e57-0000-4000-8000-000000000001', contact: '0555-44-33-22', ref: 'c3d4e5f6-0000-4000-8000-0000000000dd', period: '2026-11-19T00:00:00+06:00' }] }, { mode: 'unknown' });
  const su = JSON.stringify(u);
  for (const bad of ['Асанова', 'Иванов', '0555']) assert.ok(!su.includes(bad), `${bad}: ${su}`);
  assert.ok(su.includes('c3d4e5f6-0000-4000-8000-0000000000dd') && su.includes('2026-11-19T00:00:00+06:00'));
});

test('E9 без ложных срабатываний: коды и номера УТ, штрихкод, соглашения — не ПДн', () => {
  const m = new Masker();
  // соглашение: наименование скрыто, но в список имён клиентов не попадает
  const j = m.maskJson({ items: [{ type: 'Catalog_СоглашенияСКлиентами', description: 'Основное соглашение' }] });
  assert.equal(j.items[0].description, MASK_NAME);
  for (const t of ['Клиент с таким телефоном уже есть: код 00-00000045', 'Товар 00-00001234 «Смеситель» помечен на удаление',
    'Документ 0000-000123 от 19.11.2026 не проведён', 'Штрихкод 04607001234567 не найден', 'Основное соглашение закрыто', 'Сумма 250000000.00 и 16007.50']) {
    assert.deepEqual(m.findPii(t), [], t);
  }
  for (const t of ['Клиент с таким телефоном уже есть: код 00-00000045', 'Товар 00-00001234 «Смеситель» помечен на удаление', 'Документ 0000-000123 от 19.11.2026']) {
    assert.equal(m.maskText(t), t, 'коды и номера 1С в протоколе остаются');
  }
  assert.deepEqual(m.maybePii('Штрихкод 04607001234567 не найден'), ['возможно, ИНН (14 цифр)']);
  assert.deepEqual(m.findPii('ИНН 1234 5678 9012 34 занят'), ['ИНН']);
});

test('секрет с цифрами ИНН или телефона: сначала вычистка, потом маска — секрет не «разрезан»', () => {
  const r = new Redactor();
  r.add('Test-Klyuch-12345678901234-zz');
  r.add('Parol!0555123456');
  r.add('vymysel@klyuch.test');
  const m = new Masker({ redactor: r });
  const s = m.maskText('debug Test-Klyuch-12345678901234-zz, Parol!0555123456, vymysel@klyuch.test');
  assert.equal(s, 'debug ***, ***, ***');
  const j = JSON.stringify(m.maskJson({ debugNode: 'Test-Klyuch-12345678901234-zz', code: 'Parol!0555123456' }));
  assert.ok(!/Klyuch|Parol|12345678901234|0555123456/.test(j), j);
});

test('вычистка заголовков не трогает подписи проверок («без заголовка X-POS-Client-Key — 401 …»)', () => {
  const r = new Redactor();
  for (const t of ['без X-POS-Client-Key: 401 без тела — нет тела ошибки', 'без заголовка X-POS-Client-Key — нужен 401, пришёл 403', 'без X-POS-Client-Key: нет ответа за отведённое время']) {
    assert.equal(r.redact(t), t);
  }
  assert.equal(r.redact('GET /x\nX-POS-Client-Key: neizvestnyj\n'), 'GET /x\nX-POS-Client-Key: ***\n');
});

test('вычистка: заголовки в любом виде дампа (строка, JSON, util.inspect) и формы секрета', () => {
  const r = new Redactor();
  r.add('Vymysel-Parol/Sekret 1');
  r.addBasic('pos_hs', 'Vymysel-Parol/Sekret 1');
  r.add('vymysel-klyuch-0001');
  const basic = Buffer.from('pos_hs:Vymysel-Parol/Sekret 1').toString('base64');
  const other = Buffer.from('pos_hs:neverno-123').toString('base64'); // не зарегистрирован: убирается по имени заголовка
  const dumps = [
    `Authorization: Basic ${other}\r\nX-POS-Client-Key: neizvestnyj-klyuch-1`,
    JSON.stringify({ Authorization: `Basic ${other}`, 'X-POS-Client-Key': 'neizvestnyj-klyuch-2' }),
    util.inspect({ headers: { authorization: `Basic ${other}`, 'x-pos-client-key': 'neizvestnyj-klyuch-3' } }),
    `Bearer в заголовке: Authorization = "Bearer eyJhbGciOiJIUzI1NiJ9.e30.podpis"`,
    `пароль Vymysel-Parol/Sekret 1, url ${encodeURIComponent('Vymysel-Parol/Sekret 1')}, basic ${basic}, ключ vymysel-klyuch-0001`,
  ];
  for (const d of dumps) {
    const s = r.redact(d);
    for (const bad of [other, basic, 'neizvestnyj-klyuch', 'eyJhbGciOiJIUzI1NiJ9', 'Vymysel-Parol', 'vymysel-klyuch']) {
      assert.ok(!s.includes(bad), `«${bad.slice(0, 8)}…» в: ${s}`);
    }
  }
});

// fix2: имена и адреса в полях вне контракта и в свободном тексте; ФИО без слова-подсказки (Y2, Y10, V35, V36).
test('fix2: поля вне контракта 1.2.0 скрыты целиком (кроме GUID, дат, чисел); русские и транслит-ключи по смыслу', () => {
  const m = new Masker();
  const body = {
    customerRef: 'c3d4e5f6-0000-4000-8000-000000000001', balance: '12300.00',
    КонтактноеЛицо: 'Вымышленная Гульнара Асановна', Ответственный: 'Вымышленный Азамат Бекович', Менеджер: 'Вымышленный Менеджер',
    Покупатель: 'Вымышленный Покупатель', Получатель: 'Вымышленная Получательница', adresDostavki: 'г. Бишкек, ул. Вымышленная, 99',
    deliveryPlace: 'мкр. Вымышленный, д. 5', otvetstvennyi: 'Вымышленный Отв', zametka: 'позвонить Вымышленному после 18',
    note: 'Асанов Бакыт Жумабекович, ул. Вымышленная 7', telefonDop: '0555-98-76-54', innNomer: '01987654321098',
    extraGuid: 'f1e2d3c4-0000-4000-8000-000000000031', extraDate: '2026-11-19T10:00:00+06:00', extraSum: '850.00',
    КлиентСсылка: 'c3d4e5f6-0000-4000-8000-000000000002',
    Контакт: { Имя: 'Вымышленная Айгуль', Телефон: '+996555987654', Комментарий: 'звонить вечером' },
  };
  const foreign = new Set(Object.keys(body).filter((k) => !['customerRef', 'balance'].includes(k)));
  const j = m.maskJson(body, { foreignPaths: foreign });
  const s = JSON.stringify(j);
  for (const bad of ['Гульнара', 'Азамат', 'Вымышленный Менеджер', 'Вымышленный Покупатель', 'Получательница', 'Бишкек', 'Вымышленная, 99',
    'Вымышленный, д. 5', 'Вымышленный Отв', 'позвонить', 'Жумабекович', 'Вымышленная 7', '98-76', '987654', '01987654321098', 'Айгуль', 'вечером']) {
    assert.ok(!s.includes(bad), `«${bad}» в: ${s}`);
  }
  assert.equal(j.customerRef, body.customerRef);
  assert.equal(j.balance, '12300.00');
  assert.equal(j.extraGuid, body.extraGuid);
  assert.equal(j.extraDate, body.extraDate);
  assert.equal(j.extraSum, '850.00');
  assert.equal(j.КлиентСсылка, body.КлиентСсылка);
  assert.equal(j.КонтактноеЛицо, MASK_NAME);
  assert.equal(j.adresDostavki, MASK_ADDRESS);
  assert.equal(j.zametka, MASK_TEXT);
  assert.equal(j.telefonDop, '+996 *** ** 54');
  // Без списка путей (тело ошибки не по формату, ответ без схемы) — по смыслу ключа и по виду значения.
  const k = JSON.stringify(m.maskJson({ КонтактноеЛицо: 'Вымышленная Гульнара', Ответственный: 'Вымышленный Азамат', Менеджер: 'Вымышленный Ман',
    Покупатель: 'Вымышленный Пок', Получатель: 'Вымышленный Пол', adresDostavki: 'Бишкек, Вымышленная 99', deliveryPlace: 'Вымышленное место',
    note: 'Асанов Бакыт Жумабекович, г. Бишкек, ул. Вымышленная, 99' }));
  for (const bad of ['Гульнара', 'Азамат', 'Вымышленный Ман', 'Вымышленный Пок', 'Вымышленный Пол', 'Бишкек', 'Вымышленная 99', 'Вымышленное место', 'Жумабекович', 'Асанов']) {
    assert.ok(!k.includes(bad), `«${bad}» в: ${k}`);
  }
});

test('fix2: ФИО с отчеством, «уулу»/«кызы», «Фамилия И. О.» и адреса скрыты в любом тексте; товары, склады, коды — нет', () => {
  const m = new Masker();
  const cases = [
    ['Асанов Бакыт Жумабекович: карточка не найдена', 'Жумабекович'],
    ['Вымышленная Гульнара Асановна', 'Гульнара'],
    ['Асанов Бакыт Жумабек уулу — дубль', 'Бакыт'],
    ['звонила Айгуль Асанбек кызы', 'Айгуль'],
    ['ответственный Асанов Б. Ж.', 'Асанов'],
    ['Б.Ж. Асанов подписал', 'Асанов'],
    ['Asanov Bakyt Zhumabekovich', 'Bakyt'],
    ['доставка: г. Бишкек, ул. Вымышленная, 99', 'Вымышленная, 99'],
    ['мкр. Вымышленный, д. 5, кв. 12', 'кв. 12'],
  ];
  for (const [t, bad] of cases) {
    const s = m.maskText(t);
    assert.ok(!s.includes(bad), `${t} → ${s}`);
  }
  for (const keep of ['Смеситель для кухни однорычажный', 'Основной склад', 'Коробка (6 шт)', 'Документ 0000-000123 от 19.11.2026 г. не проведён',
    'нет ответа за 6 с — POS считает результат неизвестным', 'Труба 20 мм, 10 кв. м', 'Склад Аламедин', 'ПРОВЕРКА POS клиент 101010 (удалить)']) {
    assert.equal(m.maskText(keep), keep, keep);
  }
  // «Фамилия Имя» без отчества — в тексте ошибки 1С (message) скрыто, в прочих текстах (товары, склады) — нет.
  assert.equal(m.maskText('Токтогулова Айгуль не найдена', { weakNames: true }), `${MASK_NAME} не найдена`);
  const e = m.maskJson({ code: 'POS_E_NOT_FOUND', message: 'Токтогулова Айгуль не найдена', requestId: 'a1b2c3d4-0000-4000-8000-0000000000a9',
    details: { lines: [{ lineNumber: 1, text: 'получатель Иванова Мария' }] } });
  assert.equal(e.message, `${MASK_NAME} не найдена`);
  assert.ok(!e.details.lines[0].text.includes('Мария'), e.details.lines[0].text);
});

test('fix2: E9 — ФИО без слова-подсказки и «Фамилия Имя» после «партнёр» — ОШИБКА; одно слово, склад — ЗАМЕЧАНИЕ', () => {
  const m = new Masker();
  assert.deepEqual(m.findPii('Асанов Бакыт Жумабекович: карточка не найдена'), ['имя клиента']);
  assert.deepEqual(m.findPii('Партнёр Токтогулова Айгуль не найден'), ['имя клиента']);
  assert.deepEqual(m.findPii('Клиент Асанов Б. Ж. заблокирован'), ['имя клиента']);
  assert.deepEqual(m.findPii('Айгуль Асанбек кызы: дубль'), ['имя клиента']);
  assert.deepEqual(m.findPii('Клиент Жумабеков уже есть'), []);
  assert.deepEqual(m.maybePii('Клиент Жумабеков уже есть'), ['возможно, имя клиента']);
  assert.deepEqual(m.findPii('Склад Аламедин закрыт'), []);
  assert.deepEqual(m.maybePii('Склад Аламедин закрыт'), ['возможно, имя клиента']);
  assert.deepEqual(m.maybePii('Доставка на ул. Вымышленная, 5 невозможна'), ['возможно, адрес']);
  for (const t of ['Заказ не найден', 'Документ 0000-000123 от 19.11.2026 г. не проведён', 'Товар «Смеситель для кухни» помечен на удаление',
    'Основное соглашение закрыто', 'Клиент с таким телефоном уже есть: код 00-00000045']) {
    assert.deepEqual(m.findPii(t), [], t);
  }
});

test('fix2: ключи контракта 1.2.0 по-прежнему видны (вид по имени ключа не изменился)', () => {
  const contractKeys = ['customerRef', 'partnerRef', 'contractorRef', 'customer', 'description', 'fullName', 'productName', 'name', 'comment',
    'courierComment', 'reasonText', 'createdByUserCode', 'cashierUserCode', 'documentType', 'warehouseRef', 'organizationRef', 'brand'];
  for (const k of contractKeys) assert.equal(kindOfKey(k), null, k);
  assert.equal(kindOfKey('receiverName'), 'name');
  assert.equal(kindOfKey('address'), 'address');
  for (const [k, v] of [['КонтактноеЛицо', 'name'], ['Ответственный', 'name'], ['Менеджер', 'name'], ['Покупатель', 'name'], ['Получатель', 'name'],
    ['otvetstvennyi', 'name'], ['adresDostavki', 'address'], ['deliveryPlace', 'address'], ['МестоДоставки', 'address'], ['telefonDop', 'phone'],
    ['ЭлектроннаяПочта', 'email'], ['innNomer', 'inn'], ['КлиентСсылка', null], ['КодКлиента', null], ['ВидКлиента', null]]) {
    assert.equal(kindOfKey(k), v, k);
  }
});

test('fix3: «Розничный покупатель» и прочие общие имена — не имя клиента; однословное имя организации — ЗАМЕЧАНИЕ, не ОШИБКА; в «…» товара — не ОШИБКА (F08)', () => {
  const m = new Masker();
  m.collectNames({ items: [
    { type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000f8', description: 'Розничный покупатель', fullName: null },
    { type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000f7', description: 'Физическое лицо', fullName: 'Не указан' },
    { type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000f9', description: 'Мастер', fullName: 'ОсОО «Мастер»' },
    { type: 'Catalog_Контрагенты', ref: 'c3d4e5f6-0000-4000-8000-0000000000fa', description: 'Бакытбек', kind: 'individual' },
    { type: 'Catalog_Контрагенты', ref: 'c3d4e5f6-0000-4000-8000-0000000000fb', description: 'Стройка', kind: 'legal' },
    { type: 'Catalog_Партнеры', ref: 'c3d4e5f6-0000-4000-8000-0000000000fc', description: 'Вымыслов Тестбек' },
  ] });
  assert.ok(!m.names.has('Розничный покупатель') && !m.weakNames.has('Розничный покупатель'));
  assert.ok(!m.names.has('Физическое лицо') && !m.names.has('Не указан'));
  assert.ok(m.weakNames.has('Мастер') && !m.names.has('Мастер'));
  assert.ok(m.names.has('Бакытбек'), 'однословное имя физлица — имя клиента');
  assert.ok(m.weakNames.has('Стройка'));
  const t1 = 'Клиент не найден; продажу без клиента оформляйте на «Розничный покупатель»';
  assert.deepEqual(m.findPii(t1), []);
  assert.deepEqual(m.maybePii(t1), []);
  assert.equal(m.maskText(t1), t1, '«Розничный покупатель» не скрывается');
  const t2 = 'Файл не найден: картинка товара «Клей плиточный Мастер 25 кг» удалена';
  assert.deepEqual(m.findPii(t2), []);
  assert.deepEqual(m.maybePii(t2), []);
  assert.deepEqual(m.findPii('Клиент Мастер заблокирован'), []);
  assert.deepEqual(m.maybePii('Клиент Мастер заблокирован'), ['возможно, имя клиента']);
  assert.deepEqual(m.findPii('Мастерок штукатурный 200 мм не найден'), [], 'одно слово — только целым словом');
  assert.deepEqual(m.findPii('Карточка Бакытбек не найдена'), ['имя клиента']);
  // Имя клиента из двух слов внутри «…» наименования товара — ЗАМЕЧАНИЕ; вне кавычек — ОШИБКА.
  assert.deepEqual(m.findPii('Товар «Набор Вымыслов Тестбек 5 шт» снят с продажи'), []);
  assert.deepEqual(m.maybePii('Товар «Набор Вымыслов Тестбек 5 шт» снят с продажи'), ['возможно, имя клиента']);
  assert.deepEqual(m.findPii('Вымыслов Тестбек: карточка заблокирована'), ['имя клиента']);
  // Маска: однословное имя скрывается только целым словом.
  assert.equal(m.maskText('Мастер и Мастерок'), `${MASK_NAME} и Мастерок`);
});
