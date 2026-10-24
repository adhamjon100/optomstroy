import http from 'node:http';
import https from 'node:https';

/**
 * HTTP-транспорт адаптеров 1С (RM-E-001): `node:http(s)` без сторонних зависимостей (как SMSPro-транспорт).
 * Таймауты 05 SYNC-030: соединение 5 с, чтение — по вызову (страница `/changes` 60 с, `/images` 120 с, синхронные
 * вызовы `ONEC_SYNC_CHECK_TIMEOUT_MS`, прочие `ONEC_TIMEOUT_MS`). Только HTTPS (05 ONEC-081); `http://` допускается
 * лишь при явном `allowInsecureHttp` (локальный HTTP-мок тестов, `APP_ENV=dev`).
 *
 * Транспорт не логирует заголовки (`Authorization`, `X-POS-Client-Key`) и тела; в ошибке — только вид сбоя и код.
 */
export interface OnecHttpRequest {
  readonly method: 'GET' | 'POST';
  readonly url: string;
  readonly headers: Readonly<Record<string, string>>;
  readonly body?: Buffer;
  /** Таймаут ожидания ответа целиком, мс. */
  readonly timeoutMs: number;
  readonly signal?: AbortSignal;
}

export interface OnecHttpResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: Buffer;
}

export interface OnecHttpTransport {
  request(req: OnecHttpRequest): Promise<OnecHttpResponse>;
}

/** Сбой транспорта (таймаут, сеть, превышение размера, запрещённая схема). */
export class OnecTransportError extends Error {
  override readonly name = 'OnecTransportError';

  constructor(
    readonly kind: 'timeout' | 'connect_timeout' | 'network' | 'too_large' | 'insecure' | 'aborted',
    readonly causeCode?: string,
  ) {
    super(`1С transport: ${kind}${causeCode ? ` (${causeCode})` : ''}`);
  }
}

export interface NodeOnecTransportOptions {
  /** PEM корневого сертификата 1С (`ONEC_CA_CERT_FILE`) для внутреннего CA. */
  readonly caCert?: string;
  /** Разрешить `http://` (только локальные моки тестов / `APP_ENV=dev`). */
  readonly allowInsecureHttp?: boolean;
  /** Таймаут установления соединения, мс (05 SYNC-030: 5 с). */
  readonly connectTimeoutMs?: number;
  /** Предел тела ответа (страница `/changes` до 5000 элементов, изображения — до десятков МБ). */
  readonly maxResponseBytes?: number;
  readonly maxSockets?: number;
}

export const DEFAULT_CONNECT_TIMEOUT_MS = 5_000;
export const DEFAULT_MAX_RESPONSE_BYTES = 64 * 1024 * 1024;

export class NodeOnecTransport implements OnecHttpTransport {
  private readonly httpsAgent: https.Agent;
  private readonly httpAgent: http.Agent;
  private readonly connectTimeoutMs: number;
  private readonly maxBytes: number;

  constructor(private readonly options: NodeOnecTransportOptions = {}) {
    const maxSockets = options.maxSockets ?? 4;
    this.httpsAgent = new https.Agent({
      keepAlive: true,
      maxSockets,
      ...(options.caCert ? { ca: options.caCert } : {}),
    });
    this.httpAgent = new http.Agent({ keepAlive: true, maxSockets });
    this.connectTimeoutMs = options.connectTimeoutMs ?? DEFAULT_CONNECT_TIMEOUT_MS;
    this.maxBytes = options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
  }

  request(req: OnecHttpRequest): Promise<OnecHttpResponse> {
    const target = new URL(req.url);
    const secure = target.protocol === 'https:';
    if (!secure && !(target.protocol === 'http:' && this.options.allowInsecureHttp)) {
      return Promise.reject(new OnecTransportError('insecure', target.protocol));
    }
    if (req.signal?.aborted) return Promise.reject(new OnecTransportError('aborted'));
    const lib = secure ? https : http;
    return new Promise<OnecHttpResponse>((resolve, reject) => {
      let settled = false;
      let connected = false;
      const finish = (err: Error | null, res?: OnecHttpResponse): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        clearTimeout(connectTimer);
        req.signal?.removeEventListener('abort', onAbort);
        if (err) reject(err);
        else resolve(res!);
      };
      const headers: Record<string, string> = { ...req.headers };
      if (req.body) headers['Content-Length'] = String(req.body.length);
      const request = lib.request(
        target,
        { method: req.method, agent: secure ? this.httpsAgent : this.httpAgent, headers },
        (res) => {
          const chunks: Buffer[] = [];
          let size = 0;
          res.on('data', (c: Buffer) => {
            size += c.length;
            if (size > this.maxBytes) {
              request.destroy();
              finish(new OnecTransportError('too_large'));
              return;
            }
            chunks.push(c);
          });
          res.on('end', () => {
            const outHeaders: Record<string, string> = {};
            for (const [k, v] of Object.entries(res.headers)) {
              if (v !== undefined) outHeaders[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : v;
            }
            finish(null, { status: res.statusCode ?? 0, headers: outHeaders, body: Buffer.concat(chunks) });
          });
          res.on('error', (e: NodeJS.ErrnoException) => finish(new OnecTransportError('network', e.code)));
        },
      );
      const onAbort = (): void => {
        request.destroy();
        finish(new OnecTransportError('aborted'));
      };
      req.signal?.addEventListener('abort', onAbort, { once: true });
      const timer = setTimeout(() => {
        request.destroy();
        finish(new OnecTransportError('timeout'));
      }, req.timeoutMs);
      timer.unref();
      const connectTimer = setTimeout(() => {
        if (connected) return;
        request.destroy();
        finish(new OnecTransportError('connect_timeout'));
      }, this.connectTimeoutMs);
      connectTimer.unref();
      request.on('socket', (socket) => {
        const markConnected = (): void => {
          connected = true;
          clearTimeout(connectTimer);
        };
        if (!socket.connecting) markConnected();
        else socket.once(secure ? 'secureConnect' : 'connect', markConnected);
      });
      request.on('error', (e: NodeJS.ErrnoException) => finish(new OnecTransportError('network', e.code)));
      request.end(req.body);
    });
  }

  /** Закрыть keep-alive сокеты (остановка процесса, тесты). */
  close(): void {
    this.httpsAgent.destroy();
    this.httpAgent.destroy();
  }
}
