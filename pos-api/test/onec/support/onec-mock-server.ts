import { readdirSync, readFileSync } from 'node:fs';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { DEFAULT_ONEC_FIXTURES_DIR } from '../../../src/integrations/onec/fake-onec.gateway.js';

/** Запрос, увиденный мок-сервером 1С (для проверок заголовков и повторов). */
export interface SeenRequest {
  readonly method: string;
  readonly path: string;
  readonly query: URLSearchParams;
  readonly headers: http.IncomingHttpHeaders;
  readonly body: string;
}

export interface MockResponse {
  readonly status: number;
  readonly body?: unknown;
  readonly raw?: Buffer;
  readonly headers?: Record<string, string>;
  /** Задержка ответа, мс (проверка таймаута). */
  readonly delayMs?: number;
}

type Handler = (req: SeenRequest) => MockResponse | undefined;

/**
 * Локальный HTTP-мок сервиса расширения 1С `/<publication>/hs/pos/v1/*` на фикстурах `contracts/onec/fixtures`
 * (тестовые данные). Маршрут → фикстура по полю `operation` (`GET /pos/v1/health` → `health.200`); переопределения —
 * `on(method, pathRegex, handler)`. Каждый запрос пишется в `seen`. Ответ эхо-возвращает `X-Request-Id`.
 */
export class OnecMockServer {
  readonly seen: SeenRequest[] = [];
  private server: http.Server | undefined;
  private readonly overrides: { method: string; path: RegExp; handler: Handler }[] = [];
  private readonly fixtures = new Map<string, { status: number; body: unknown }>();
  readonly prefix: string;
  port = 0;

  constructor(prefix = '/ut11/hs') {
    this.prefix = prefix;
    for (const f of readdirSync(DEFAULT_ONEC_FIXTURES_DIR).filter((x) => x.endsWith('.json'))) {
      const raw = JSON.parse(readFileSync(join(DEFAULT_ONEC_FIXTURES_DIR, f), 'utf8')) as {
        operation: string;
        kind: string;
        status?: number;
        body: unknown;
      };
      if (raw.kind !== 'response' || (raw.status ?? 200) >= 300) continue;
      // Успешная фикстура операции по умолчанию: первая по имени (health.200, changes.catalog.page1.200, …).
      if (!this.fixtures.has(raw.operation))
        this.fixtures.set(raw.operation, { status: raw.status ?? 200, body: raw.body });
    }
  }

  /** Тело фикстуры по имени файла без `.json`. */
  static fixture(name: string): { status: number; body: unknown } {
    const raw = JSON.parse(readFileSync(join(DEFAULT_ONEC_FIXTURES_DIR, `${name}.json`), 'utf8')) as {
      status?: number;
      body: unknown;
    };
    return { status: raw.status ?? 200, body: raw.body };
  }

  /** Снять все переопределения маршрутов и журнал запросов. */
  reset(): void {
    this.overrides.length = 0;
    this.seen.length = 0;
  }

  on(method: string, path: RegExp, handler: Handler): this {
    this.overrides.unshift({ method, path, handler });
    return this;
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  async start(): Promise<void> {
    this.server = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const url = new URL(req.url ?? '/', 'http://x');
        const path = url.pathname.startsWith(this.prefix) ? url.pathname.slice(this.prefix.length) : url.pathname;
        const seen: SeenRequest = {
          method: req.method ?? 'GET',
          path: decodeURIComponent(path),
          query: url.searchParams,
          headers: req.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        };
        this.seen.push(seen);
        const r = this.route(seen) ?? {
          status: 404,
          body: { code: 'POS_E_NOT_FOUND', message: 'нет маршрута', requestId: '00000000-0000-4000-8000-000000000000' },
        };
        const send = (): void => {
          const headers: Record<string, string> = { ...(r.headers ?? {}) };
          const rid = req.headers['x-request-id'];
          if (typeof rid === 'string') headers['X-Request-Id'] = rid;
          headers['X-POS-API-Version'] = '1';
          let payload: Buffer | undefined = r.raw;
          if (!payload && r.body !== undefined) {
            payload = Buffer.from(JSON.stringify(r.body), 'utf8');
            headers['Content-Type'] = 'application/json; charset=utf-8';
          }
          res.writeHead(r.status, headers);
          res.end(payload);
        };
        if (r.delayMs) setTimeout(send, r.delayMs);
        else send();
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, '127.0.0.1', resolve));
    this.port = (this.server.address() as AddressInfo).port;
  }

  async stop(): Promise<void> {
    if (!this.server) return;
    this.server.closeAllConnections();
    await new Promise<void>((resolve) => this.server!.close(() => resolve()));
  }

  private route(req: SeenRequest): MockResponse | undefined {
    for (const o of this.overrides) {
      if (o.method === req.method && o.path.test(req.path)) {
        const r = o.handler(req);
        if (r) return r;
      }
    }
    const template = req.path
      .replace(/^\/pos\/v1\/orders\/[0-9a-f-]{36}\/status$/, '/pos/v1/orders/{uuid}/status')
      .replace(/^\/pos\/v1\/orders\/[0-9a-f-]{36}\/cancel$/, '/pos/v1/orders/{uuid}/cancel')
      .replace(/^\/pos\/v1\/catalog\/[0-9a-f-]{36}$/, '/pos/v1/catalog/{ref}')
      .replace(/^\/pos\/v1\/customers\/[0-9a-f-]{36}\/receivables$/, '/pos/v1/customers/{ref}/receivables')
      .replace(/^\/pos\/v1\/returns\/[0-9a-f-]{36}\/status$/, '/pos/v1/returns/{uuid}/status')
      .replace(/^\/pos\/v1\/payments\/[0-9a-f-]{36}\/status$/, '/pos/v1/payments/{externalId}/status');
    const f = this.fixtures.get(`${req.method} ${template}`);
    return f ? { status: f.status, body: f.body } : undefined;
  }
}
