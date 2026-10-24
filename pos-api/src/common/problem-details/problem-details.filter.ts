import { type ArgumentsHost, Catch, type ExceptionFilter, Inject, Logger } from '@nestjs/common';
import type { Request, Response } from 'express';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { getRequestId } from '../http/request-context.js';
import { IDEMPOTENT_REPLAYED_HEADER } from '../idempotency/idempotent.decorator.js';
import { ReplayedResponseException } from '../idempotency/replayed-response.exception.js';
import { newId } from '../ids/uuid.js';
import { DEV_PROBLEM_BASE_URL, PROBLEM_CONTENT_TYPE, toProblem } from './problem-details.js';

/**
 * Глобальный фильтр RFC 9457 (RM-C-005): любое исключение → `application/problem+json` с `code` из 08 §2.4.
 * Заголовки, выставленные до ошибки (X-Request-Id, X-Min-App-Version …), сохраняются.
 * Особый случай — повтор сохранённого ответа идемпотентного запроса (08 §2.7): тело отдаётся как есть.
 */
@Catch()
export class ProblemDetailsFilter implements ExceptionFilter {
  private readonly logger = new Logger('ProblemDetails');
  private readonly baseUrl: string;

  constructor(@Inject(APP_CONFIG) config: Pick<AppConfig, 'PUBLIC_BASE_URL'>) {
    this.baseUrl = config.PUBLIC_BASE_URL ?? DEV_PROBLEM_BASE_URL;
  }

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest<Request & { id?: string }>();
    const res = ctx.getResponse<Response>();
    if (res.headersSent) return;

    if (exception instanceof ReplayedResponseException) {
      res.setHeader(IDEMPOTENT_REPLAYED_HEADER, 'true');
      res.status(exception.replayStatus);
      if (exception.isProblem) {
        res.setHeader('Content-Language', 'ru');
        res.type(PROBLEM_CONTENT_TYPE).send(JSON.stringify(exception.replayBody));
      } else {
        res.json(exception.replayBody);
      }
      return;
    }

    const requestId = getRequestId(req) ?? newId();
    const problem = toProblem(exception, requestId, this.baseUrl);
    if (problem.internal) {
      // Сообщение и стек — только в лог (redaction — common/logging); клиенту — нейтральный detail.
      this.logger.error({ err: exception, requestId, code: problem.body.code }, 'unhandled exception');
    }
    for (const [k, v] of Object.entries(problem.headers)) res.setHeader(k, v);
    res.setHeader('Content-Language', 'ru');
    res.status(problem.status).type(PROBLEM_CONTENT_TYPE).send(JSON.stringify(problem.body));
  }
}
