import { classifySmsProStatus, deliveryStateOfReport, toSmsProPhone } from '../../src/integrations/sms/sms-gateway.js';
import {
  buildDrXml,
  buildInfoXml,
  buildMessageXml,
  parseDlrPush,
  parseDrResponse,
  parseInfoResponse,
  parseMessageResponse,
  parseSmsProTime,
  parseXml,
  xmlEscape,
  XmlParseError,
} from '../../src/integrations/sms/smspro-xml.js';

/**
 * T-SMS-001…T-SMS-003 (unit): формат запроса и разбор ответов на фикстурах документации 09 §6.2–§6.6 / R2 §3–§5
 * (вариант PDF без namespace и фактический — с `xmlns` и без `<message>`).
 */
describe('XML SMSPro: построение запросов (09 §6.2, §6.5, §6.6; SMS-004, SMS-005, SMS-009)', () => {
  it('/api/message — ровно теги документации, без time; test только по флагу; текст экранирован', () => {
    const xml = buildMessageXml({
      login: 'log<in',
      pwd: 'p&w"d',
      id: 'A88726B4C9D1',
      sender: 'Optomstroy',
      text: `Kod: 004512. <O&O> 'x'`,
      phone: '996700000001',
      test: false,
    });
    expect(xml).toBe(
      '<?xml version="1.0" encoding="UTF-8"?><message><login>log&lt;in</login><pwd>p&amp;w&quot;d</pwd>' +
        '<id>A88726B4C9D1</id><sender>Optomstroy</sender>' +
        '<text>Kod: 004512. &lt;O&amp;O&gt; &apos;x&apos;</text><phones><phone>996700000001</phone></phones></message>',
    );
    const tree = parseXml(xml);
    expect(tree.children.map((c) => c.name)).toEqual(['login', 'pwd', 'id', 'sender', 'text', 'phones']);
    expect(xml).not.toContain('<time>');
    expect(xml).not.toContain('<test>');
    const withTest = buildMessageXml({
      login: 'l',
      pwd: 'p',
      id: 'A88726B4C9D1',
      sender: 'S',
      text: 't',
      phone: '996700000001',
      test: true,
    });
    expect(withTest).toContain('</phones><test>1</test></message>');
    // кириллица — UTF-8 как есть
    expect(
      parseXml(buildMessageXml({ login: 'l', pwd: 'p', id: 'x', sender: 's', text: 'Код: 1', phone: '1', test: false }))
        .children[4]?.text,
    ).toBe('Код: 1');
  });

  it('/api/dr — с phone всегда; /api/info — с namespace как в документации', () => {
    expect(buildDrXml({ login: 'l', pwd: 'p', id: 'A88726B4C9D1', phone: '996550123456' })).toBe(
      '<?xml version="1.0" encoding="UTF-8"?><dr><login>l</login><pwd>p</pwd><id>A88726B4C9D1</id><phone>996550123456</phone></dr>',
    );
    expect(buildInfoXml({ login: 'l', pwd: 'p' })).toBe(
      '<?xml version="1.0" encoding="UTF-8"?><info xmlns="http://Giper.mobi/schema/Info"><login>l</login><pwd>p</pwd></info>',
    );
  });

  it('номер — 996XXXXXXXXX без «+» (SMS-008); вне КР — null', () => {
    expect(toSmsProPhone('+996700000001')).toBe('996700000001');
    expect(toSmsProPhone('996 700 000 001')).toBe('996700000001');
    expect(toSmsProPhone('+79120000000')).toBeNull();
  });

  it('недопустимые в XML символы в значении → ошибка (не «чистятся» молча)', () => {
    expect(() => xmlEscape('a\u0001b')).toThrow(XmlParseError);
  });
});

describe('XML SMSPro: разбор ответов (09 §6.3–§6.6; SMS-010, AC-AUTH-026)', () => {
  it('T-SMS-002: ответ по PDF (без namespace, с <message>), фактический (xmlns, без <message>) и status=2 — разобраны', () => {
    const pdf = parseMessageResponse(
      '<?xml version="1.0" encoding="UTF-8"?>\n<response>\n  <id>A88726</id>\n  <status>0</status>\n  <phones>2</phones>\n  <smscnt>2</smscnt>\n  <message></message>\n</response>',
    );
    expect(pdf).toEqual({ id: 'A88726', status: 0, phones: 2, smscnt: 2 });
    const live = parseMessageResponse(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><response xmlns="http://Giper.mobi/schema/Message"><id>T1</id><status>2</status><phones>1</phones><smscnt>1</smscnt></response>',
    );
    expect(live).toEqual({ id: 'T1', status: 2, phones: 1, smscnt: 1 });
    const prefixed = parseMessageResponse(
      '<m:response xmlns:m="http://Giper.mobi/schema/Message"><m:status>7</m:status><m:message>bad 996555</m:message></m:response>',
    );
    expect(prefixed).toMatchObject({ status: 7, message: 'bad 996555' });
  });

  it('без <status> или не-XML → ошибка разбора (класс RETRYABLE у адаптера)', () => {
    expect(() => parseMessageResponse('<response><id>1</id></response>')).toThrow(XmlParseError);
    expect(() => parseMessageResponse('<html>502 Bad Gateway')).toThrow(XmlParseError);
    expect(() => parseMessageResponse('garbage')).toThrow(XmlParseError);
    expect(() => parseMessageResponse('')).toThrow(XmlParseError);
  });

  it('DOCTYPE/сущности запрещены (XXE, billion laughs)', () => {
    const xxe =
      '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><response><status>&x;</status></response>';
    expect(() => parseMessageResponse(xxe)).toThrow(/DOCTYPE/);
    expect(() => parseMessageResponse('<response><status>&foo;</status></response>')).toThrow(/сущность/);
  });

  it('/api/dr: несколько phone, пустые времена, время Бишкека → UTC; ошибка — без phone', () => {
    const ok = parseDrResponse(
      '<?xml version="1.0" encoding="UTF-8"?><response><status>0</status>' +
        '<phone><number>996550123456</number><report>1</report><sendTime>20100921235958</sendTime><rcvTime></rcvTime></phone>' +
        '<phone><number>996550123457</number><report>3</report><sendTime>20100921235958</sendTime><rcvTime>20100921235959</rcvTime></phone>' +
        '</response>',
    );
    expect(ok.status).toBe(0);
    expect(ok.reports).toEqual([
      { number: '996550123456', report: 1, sendTime: '2010-09-21T17:59:58.000Z', rcvTime: null, state: 'PENDING' },
      {
        number: '996550123457',
        report: 3,
        sendTime: '2010-09-21T17:59:58.000Z',
        rcvTime: '2010-09-21T17:59:59.000Z',
        state: 'DELIVERED',
      },
    ]);
    expect(
      parseDrResponse(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><response xmlns="http://Giper.mobi/schema/DeliveryReport"><status>2</status></response>',
      ),
    ).toEqual({ status: 2, reports: [] });
  });

  it('/api/info: фактический ответ и ответ при неверных данных', () => {
    expect(
      parseInfoResponse(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><response xmlns="http://Giper.mobi/schema/Info"><status>0</status><state>0</state><account>20123.12</account><smsprice>0.50</smsprice></response>',
      ),
    ).toEqual({ status: 0, state: 0, account: '20123.12', smsprice: '0.50' });
    expect(
      parseInfoResponse(
        '<response xmlns="http://Giper.mobi/schema/Info"><status>2</status><state>1</state><account>0</account><smsprice>0</smsprice></response>',
      ),
    ).toEqual({ status: 2, state: 1, account: '0', smsprice: '0' });
  });

  it('push-отчёт: несколько dr и phone (09 §6.5)', () => {
    const entries = parseDlrPush(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><report xmlns="http://Giper.mobi/schema/DeliveryReport">' +
        '<dr><id>A881726</id><phone><number>996550123456</number><report>1</report><sendTime>20110909032815</sendTime><rcvTime>20110909032820</rcvTime></phone></dr>' +
        '<dr><id>A887236</id><phone><number>996550123458</number><report>3</report><sendTime>20110909032817</sendTime><rcvTime>20110909032822</rcvTime></phone></dr>' +
        '</report>',
    );
    expect(entries.map((e) => [e.id, e.reports.map((r) => r.state)])).toEqual([
      ['A881726', ['PENDING']],
      ['A887236', ['DELIVERED']],
    ]);
  });

  it('время SMSPro: пусто/неверно → null', () => {
    expect(parseSmsProTime('')).toBeNull();
    expect(parseSmsProTime(undefined)).toBeNull();
    expect(parseSmsProTime('2010-09-21')).toBeNull();
  });
});

describe('Классы исхода и report (09 §6.4, §6.5; SMS-011, T-SMS-003 — таблично 12 кодов)', () => {
  const expected: [number, string][] = [
    [0, 'ACCEPTED'],
    [1, 'PERMANENT'],
    [2, 'CONFIG_ERROR'],
    [3, 'CONFIG_ERROR'],
    [4, 'INSUFFICIENT_FUNDS'],
    [5, 'CONFIG_ERROR'],
    [6, 'PERMANENT'],
    [7, 'INVALID_PHONE'],
    [8, 'PERMANENT'],
    [9, 'RETRYABLE'],
    [10, 'DUPLICATE_ID'],
    [11, 'ACCEPTED_TEST'],
  ];
  it.each(expected)('status=%i → %s', (status, outcome) => {
    expect(classifySmsProStatus(status)).toBe(outcome);
  });
  it('неизвестный код → PERMANENT', () => {
    expect(classifySmsProStatus(12)).toBe('PERMANENT');
  });
  it('report: 3 → DELIVERED; 2/4/5/7 → FAILED; 0/1/6 → PENDING', () => {
    expect([0, 1, 2, 3, 4, 5, 6, 7].map(deliveryStateOfReport)).toEqual([
      'PENDING',
      'PENDING',
      'FAILED',
      'DELIVERED',
      'FAILED',
      'FAILED',
      'PENDING',
      'FAILED',
    ]);
  });
});
