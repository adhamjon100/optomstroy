import https from 'node:https';
import type { AddressInfo } from 'node:net';
import { parseXml, type XmlElement } from '../../../src/integrations/sms/smspro-xml.js';
import { createSelfSignedCert } from './self-signed.js';

/**
 * Локальный HTTPS-стенд SMSPro (НЕ реальный SMSPro): эндпоинты `/api/message`, `/api/dr`, `/api/info` отвечают
 * по сценарию теста; все запросы записываются (метод, путь, заголовки, тело, разобранный XML) — для проверки
 * формата (AC-AUTH-025), повторов с тем же `id` (AC-AUTH-028/029) и отсутствия сетевых вызовов (AC-AUTH-030).
 * Ответы по умолчанию — как в документации (09 §6.3–§6.6), с namespace фактических ответов.
 */
export interface MockReply {
  readonly httpStatus?: number;
  readonly body?: string;
  /** Задержка ответа (имитация таймаута клиента). */
  readonly delayMs?: number;
  /** Не отвечать вовсе (соединение висит до закрытия клиентом). */
  readonly hang?: boolean;
}

export interface RecordedRequest {
  readonly method: string;
  readonly path: string;
  readonly headers: Record<string, string | string[] | undefined>;
  readonly body: string;
  readonly xml: XmlElement | undefined;
  readonly at: number;
}

type Endpoint = 'message' | 'dr' | 'info';
type Responder = (req: RecordedRequest) => MockReply;

export const NS = {
  message: 'http://Giper.mobi/schema/Message',
  dr: 'http://Giper.mobi/schema/DeliveryReport',
  info: 'http://Giper.mobi/schema/Info',
} as const;

const DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

/** Ответ `/api/message` в фактическом виде (с `xmlns`, без `<message>`), 09 §6.3. */
export function messageReply(status: number, id = 'T1', phones = 1, smscnt = 1, message?: string): MockReply {
  return {
    body: `${DECL}<response xmlns="${NS.message}"><id>${id}</id><status>${status}</status><phones>${phones}</phones><smscnt>${smscnt}</smscnt>${
      message !== undefined ? `<message>${message}</message>` : ''
    }</response>`,
  };
}

export function drReply(
  status: number,
  phones: readonly { number: string; report: number; sendTime?: string; rcvTime?: string }[] = [],
): MockReply {
  const items = phones
    .map(
      (p) =>
        `<phone><number>${p.number}</number><report>${p.report}</report><sendTime>${p.sendTime ?? ''}</sendTime><rcvTime>${
          p.rcvTime ?? ''
        }</rcvTime></phone>`,
    )
    .join('');
  return { body: `${DECL}<response xmlns="${NS.dr}"><status>${status}</status>${items}</response>` };
}

export function infoReply(status: number, state: 0 | 1, account: string, smsprice = '0.50'): MockReply {
  return {
    body: `${DECL}<response xmlns="${NS.info}"><status>${status}</status><state>${state}</state><account>${account}</account><smsprice>${smsprice}</smsprice></response>`,
  };
}

export class MockSmsPro {
  readonly requests: RecordedRequest[] = [];
  private server: https.Server | undefined;
  private readonly queues: Record<Endpoint, MockReply[]> = { message: [], dr: [], info: [] };
  private readonly fallback: Record<Endpoint, Responder> = {
    message: (r) => messageReply(0, textOf(r.xml, 'id') ?? 'T1'),
    dr: () => drReply(4),
    info: () => infoReply(0, 0, '1000.00'),
  };
  readonly ca: string;
  private readonly key: string;
  port = 0;

  constructor() {
    const { cert, key } = createSelfSignedCert();
    this.ca = cert;
    this.key = key;
  }

  get baseUrl(): string {
    return `https://127.0.0.1:${this.port}/api`;
  }

  /** Агент клиента, доверяющий только CA стенда. */
  agent(): https.Agent {
    return new https.Agent({ ca: this.ca, keepAlive: false });
  }

  async start(): Promise<this> {
    this.server = https.createServer({ cert: this.ca, key: this.key }, (req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        let xml: XmlElement | undefined;
        try {
          xml = parseXml(body);
        } catch {
          xml = undefined;
        }
        const path = req.url ?? '';
        const rec: RecordedRequest = {
          method: req.method ?? '',
          path,
          headers: req.headers,
          body,
          xml,
          at: Date.now(),
        };
        this.requests.push(rec);
        const ep = (path.replace(/^\/api\//, '').split('?')[0] ?? '') as Endpoint;
        if (req.method !== 'POST' || !(ep in this.queues)) {
          res.writeHead(500).end('error');
          return;
        }
        const reply = this.queues[ep].shift() ?? this.fallback[ep](rec);
        if (reply.hang) return; // клиент оборвёт по таймауту
        const send = () => {
          if (res.destroyed) return;
          res.writeHead(reply.httpStatus ?? 200, { 'Content-Type': 'text/xml;charset=UTF-8' });
          res.end(reply.body ?? '');
        };
        if (reply.delayMs) setTimeout(send, reply.delayMs);
        else send();
      });
    });
    await new Promise<void>((r) => this.server!.listen(0, '127.0.0.1', r));
    this.port = (this.server.address() as AddressInfo).port;
    return this;
  }

  async stop(): Promise<void> {
    this.server?.closeAllConnections();
    await new Promise<void>((r) => (this.server ? this.server.close(() => r()) : r()));
  }

  /** Очередь ответов эндпоинта (по одному на запрос, далее — ответ по умолчанию). */
  enqueue(ep: Endpoint, ...replies: MockReply[]): void {
    this.queues[ep].push(...replies);
  }

  setDefault(ep: Endpoint, r: Responder): void {
    this.fallback[ep] = r;
  }

  reset(): void {
    this.requests.length = 0;
    for (const k of Object.keys(this.queues) as Endpoint[]) this.queues[k].length = 0;
    this.fallback.message = (r) => messageReply(0, textOf(r.xml, 'id') ?? 'T1');
    this.fallback.dr = () => drReply(4);
    this.fallback.info = () => infoReply(0, 0, '1000.00');
  }

  to(ep: Endpoint): RecordedRequest[] {
    return this.requests.filter((r) => r.path === `/api/${ep}`);
  }
}

export function textOf(xml: XmlElement | undefined, name: string): string | undefined {
  return xml?.children.find((c) => c.name === name)?.text;
}

/** Секрет-подобные значения для теста (не настоящие учётные данные). */
export const TEST_LOGIN = ['mock', 'login', 'x7'].join('-');
export const TEST_PASSWORD = ['Mock', 'Pwd', '9f2kQz'].join('_');
