import type { NextFunction, Request, Response } from 'express';

/**
 * Обязательные заголовки ответа 08 §2.3 (OWASP HTTP Headers CS): `X-Content-Type-Options`, `Cache-Control: no-store`
 * по умолчанию, `Content-Security-Policy: frame-ancestors 'none'`, `Referrer-Policy`. HSTS выставляет и pos-proxy;
 * здесь — дублирующий слой. `X-Powered-By` отключается в create-app.ts.
 */
export function securityHeadersMiddleware(_req: Request, res: Response, next: NextFunction): void {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Security-Policy', "frame-ancestors 'none'");
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
  next();
}
