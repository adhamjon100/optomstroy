import https from 'node:https';

/**
 * HTTP-транспорт адаптера SMSPro (09 §6.1): только `POST`, только `https://` (SMS-003), тело XML UTF-8 с
 * `Content-Type: application/xml` (SMS-005), таймаут одного вызова `SMSPRO_TIMEOUT_MS`. Ответ — HTTP 200 даже при
 * ошибке (решение по `<status>`), поэтому транспорт возвращает статус и тело как есть.
 *
 * Тело запроса содержит `login`/`pwd` — транспорт его не логирует и не кладёт в сообщения ошибок.
 */
export interface SmsHttpResponse {
  readonly status: number;
  readonly body: string;
}

export interface SmsHttpTransport {
  post(url: string, xmlBody: string, timeoutMs: number): Promise<SmsHttpResponse>;
}

/** Сбой транспорта: таймаут или сеть. Сообщение — без URL-параметров и тела. */
export class SmsTransportError extends Error {
  override readonly name = 'SmsTransportError';

  constructor(
    readonly kind: 'timeout' | 'network' | 'too_large',
    readonly causeCode?: string,
  ) {
    super(`SMSPro transport: ${kind}${causeCode ? ` (${causeCode})` : ''}`);
  }
}

/** Предел тела ответа: ответы вендора — сотни байт; защита от «бесконечного» тела. */
export const MAX_RESPONSE_BYTES = 256 * 1024;

export interface NodeHttpsTransportOptions {
  /** Свой агент (keep-alive по умолчанию); тесты передают агент с собственным CA локального стенда. */
  readonly agent?: https.Agent;
}

/** Транспорт на `node:https` (без сторонних зависимостей). */
export class NodeHttpsTransport implements SmsHttpTransport {
  private readonly agent: https.Agent;

  constructor(options: NodeHttpsTransportOptions = {}) {
    this.agent = options.agent ?? new https.Agent({ keepAlive: true, maxSockets: 8 });
  }

  post(url: string, xmlBody: string, timeoutMs: number): Promise<SmsHttpResponse> {
    const target = new URL(url);
    if (target.protocol !== 'https:') {
      return Promise.reject(new SmsTransportError('network', 'NOT_HTTPS'));
    }
    const payload = Buffer.from(xmlBody, 'utf8');
    return new Promise<SmsHttpResponse>((resolve, reject) => {
      let settled = false;
      const finish = (err: Error | null, res?: SmsHttpResponse): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (err) reject(err);
        else resolve(res!);
      };
      const req = https.request(
        target,
        {
          method: 'POST',
          agent: this.agent,
          headers: {
            'Content-Type': 'application/xml',
            'Content-Length': String(payload.length),
            Accept: 'application/xml, text/xml',
          },
        },
        (res) => {
          const chunks: Buffer[] = [];
          let size = 0;
          res.on('data', (c: Buffer) => {
            size += c.length;
            if (size > MAX_RESPONSE_BYTES) {
              req.destroy();
              finish(new SmsTransportError('too_large'));
              return;
            }
            chunks.push(c);
          });
          res.on('end', () =>
            finish(null, { status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }),
          );
          res.on('error', (e: NodeJS.ErrnoException) => finish(new SmsTransportError('network', e.code)));
        },
      );
      const timer = setTimeout(() => {
        req.destroy();
        finish(new SmsTransportError('timeout'));
      }, timeoutMs);
      timer.unref();
      req.on('error', (e: NodeJS.ErrnoException) => finish(new SmsTransportError('network', e.code)));
      req.end(payload);
    });
  }
}
