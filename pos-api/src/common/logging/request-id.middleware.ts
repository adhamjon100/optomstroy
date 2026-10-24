import type { NextFunction, Request, Response } from 'express';
import { isUuid, newId } from '../ids/uuid.js';

export const REQUEST_ID_HEADER = 'X-Request-Id';

/**
 * Сквозной requestId (08 §2.3, RM-C-010): если клиент прислал валидный UUID — используется он (эхо),
 * иначе генерируется UUID v7. Невалидное значение не попадает в логи (защита от log injection, SEC-066).
 * Подключается первым через `app.use` в create-app.ts; pino-http берёт `req.id` (genReqId).
 */
export function requestIdMiddleware(req: Request, res: Response, next: NextFunction): void {
  const incoming = req.header(REQUEST_ID_HEADER);
  const id = isUuid(incoming) ? incoming.toLowerCase() : newId();
  (req as Request & { id?: string }).id = id;
  res.setHeader(REQUEST_ID_HEADER, id);
  next();
}
