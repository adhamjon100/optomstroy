import type { Request } from 'express';
import { ProblemException } from '../problem-details/problem.exception.js';

/**
 * Пути, тело которых общий JSON-парсер не разбирает: обработчик читает **сырые байты** сам (подпись считается по
 * сырому телу — вебхук банка, 08 §6; ADR-123). Путь — с префиксом `/api/v1`.
 */
export const RAW_BODY_PATHS: ReadonlySet<string> = new Set(['/api/v1/payments/qr/webhook']);

/** Разбирать ли тело общим JSON-парсером (`useBodyParser('json', { type })`): `application/json` вне RAW_BODY_PATHS. */
export function jsonBodyType(req: {
  headers: Record<string, string | string[] | undefined>;
  url?: string;
  originalUrl?: string;
}): boolean {
  const raw = req.headers['content-type'];
  const ct = (Array.isArray(raw) ? (raw[0] ?? '') : (raw ?? '')).split(';')[0]?.trim().toLowerCase();
  if (ct !== 'application/json') return false;
  const path = (req.originalUrl ?? req.url ?? '').split('?')[0] ?? '';
  return !RAW_BODY_PATHS.has(path);
}

/** Сверх этого объёма тело не дочитывается (соединение обрывается). */
const DRAIN_CAP_BYTES = 8 * 1024 * 1024;

/** Сырое тело запроса с пределом `limit` байт; больше → `413 PAYLOAD_TOO_LARGE`. */
export async function readRawBody(req: Request, limit: number): Promise<Buffer> {
  const tooLarge = () => new ProblemException('PAYLOAD_TOO_LARGE', { detail: 'Тело запроса больше 1 MB.' });
  if (Buffer.isBuffer(req.body)) return req.body;
  const declared = Number(req.headers['content-length'] ?? 0); // money-double: allow — байты
  if (declared > DRAIN_CAP_BYTES) {
    req.destroy();
    throw tooLarge();
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req as AsyncIterable<Buffer | string>) {
    const b = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
    size += b.length;
    if (size > DRAIN_CAP_BYTES) {
      req.destroy();
      throw tooLarge();
    }
    if (size <= limit) chunks.push(b);
  }
  if (size > limit || declared > limit) throw tooLarge();
  return Buffer.concat(chunks);
}
