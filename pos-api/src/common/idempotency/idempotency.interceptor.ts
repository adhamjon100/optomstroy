import {
  type CallHandler,
  type ExecutionContext,
  Inject,
  Injectable,
  Logger,
  type NestInterceptor,
} from '@nestjs/common';
import { HTTP_CODE_METADATA } from '@nestjs/common/constants.js';
import { Reflector } from '@nestjs/core';
import { catchError, from, mergeMap, type Observable } from 'rxjs';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import type { RequestWithContext } from '../http/request-context.js';
import { MUTATING_METHODS, requestRouteTemplate, routeKey } from '../http/route-template.js';
import { isUuidV4Lower, newId } from '../ids/uuid.js';
import { DEV_PROBLEM_BASE_URL, toProblem } from '../problem-details/problem-details.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { requestFingerprint } from './fingerprint.js';
import { attachIdempotencyState, type IdempotencyRequestState } from './idempotency.context.js';
import { IdempotencyService, isStorableErrorStatus } from './idempotency.service.js';
import type { IdempotencyScope } from './idempotency.store.js';
import { IDEMPOTENCY_KEY_HEADER, IDEMPOTENT, type IdempotentOptions } from './idempotent.decorator.js';
import { ReplayedResponseException } from './replayed-response.exception.js';

type Req = RequestWithContext & { header(name: string): string | undefined };

/** Попыток записи итога после успешного обработчика (сбой пула/БД между COMMIT и записью). */
const COMPLETE_ATTEMPTS = 3;

/**
 * Интерсептор `Idempotency-Key` (RM-C-005; 08 §2.7). Выполняется после guard'ов (426/401/403/503 не захватывают
 * ключ). Итог запроса сохраняется отдельной командой после обработчика, если обработчик не записал его сам в
 * транзакции бизнес-операции (`IdempotencyService.recordInTransaction`, B-AR-04 — обязательно для денежных маршрутов
 * этапа F). Ключ освобождается только при ошибке обработчика до фиксации побочного эффекта (ревью C-CR-02).
 */
@Injectable()
export class IdempotencyInterceptor implements NestInterceptor {
  private readonly logger = new Logger('idempotency');
  private readonly baseUrl: string;

  constructor(
    private readonly reflector: Reflector,
    private readonly service: IdempotencyService,
    @Inject(APP_CONFIG) config: Pick<AppConfig, 'PUBLIC_BASE_URL'>,
  ) {
    this.baseUrl = config.PUBLIC_BASE_URL ?? DEV_PROBLEM_BASE_URL;
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();
    const req = context.switchToHttp().getRequest<Req>();
    const method = (req.method ?? 'GET').toUpperCase();
    if (!MUTATING_METHODS.has(method)) return next.handle();

    const options = this.reflector.get<IdempotentOptions | undefined>(IDEMPOTENT, context.getHandler());
    const required = options !== undefined && (options.requiredWhen ? options.requiredWhen(req) : options.required);
    const key = req.header(IDEMPOTENCY_KEY_HEADER);
    if (key === undefined || key === '') {
      if (required) throw validation('idempotency_key_required', 'Заголовок Idempotency-Key обязателен.');
      return next.handle();
    }
    if (!isUuidV4Lower(key)) throw validation('idempotency_key_format', 'Idempotency-Key — UUID v4 в нижнем регистре.');

    const subject =
      options?.subject?.(req) ??
      (req.principal ? { subjectKey: `user:${req.principal.userId}`, userId: req.principal.userId } : undefined);
    if (!subject) {
      // Публичный маршрут без определённого субъекта: ключ «допускается», но хранить его не к чему привязать.
      if (required) {
        this.logger.error({ route: requestRouteTemplate(req) }, 'idempotent route without subject resolver');
        throw new ProblemException('INTERNAL');
      }
      return next.handle();
    }

    const scope: IdempotencyScope = {
      key,
      subjectKey: subject.subjectKey,
      userId: subject.userId,
      route: routeKey(method, requestRouteTemplate(req)),
    };
    const hash = requestFingerprint(req.params ?? {}, req.body);
    const successStatus =
      this.reflector.get<number | undefined>(HTTP_CODE_METADATA, context.getHandler()) ??
      (method === 'POST' ? 201 : 200);

    return from(this.service.begin(scope, hash)).pipe(
      mergeMap((begin) => {
        if (begin.kind === 'replay') throw new ReplayedResponseException(begin.status, begin.body);
        const state = attachIdempotencyState(req, scope);
        return next.handle().pipe(
          // Только ошибки обработчика: сбой записи итога после успешного обработчика сюда не попадает (C-CR-02).
          catchError(async (err: unknown) => {
            await this.onHandlerError(state, err, req);
            throw err;
          }),
          mergeMap(async (body: unknown) => {
            if (!state.recordedInTx) await this.completeAfterSuccess(state, successStatus, body, req);
            return body;
          }),
        );
      }),
    );
  }

  /**
   * Обработчик выполнился успешно — побочный эффект уже зафиксирован. Итог пишется с повторами; если запись так и не
   * удалась, ключ **не освобождается** (остаётся `in_progress` до TTL: повтор получит 409, а не второе выполнение
   * операции), клиент получает настоящий ответ обработчика (08 §2.7; ревью C-CR-02).
   */
  private async completeAfterSuccess(
    state: IdempotencyRequestState,
    status: number,
    body: unknown,
    req: Req,
  ): Promise<void> {
    let lastError: unknown;
    for (let attempt = 1; attempt <= COMPLETE_ATTEMPTS; attempt++) {
      try {
        await this.service.complete(state.scope, status, body);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    this.logger.error(
      { event: 'idempotency.complete_failed', requestId: req.id, route: state.scope.route, err: lastError },
      'idempotency.complete_failed: key kept in_progress (no release after successful handler)',
    );
  }

  /**
   * Обработчик бросил ошибку. Ключ освобождается, только если побочный эффект не зафиксирован вне записи итога:
   * после `markIdempotencyCommitted(req)` ключ остаётся `in_progress` (fail-safe). Бизнес-ошибки 404/409/422
   * сохраняются для повтора; если сохранить не удалось — ключ освобождается (операция не выполнялась).
   */
  private async onHandlerError(state: IdempotencyRequestState, err: unknown, req: Req): Promise<void> {
    if (state.committed && !state.recordedInTx) {
      this.logger.error(
        { event: 'idempotency.error_after_commit', requestId: req.id, route: state.scope.route },
        'idempotency.error_after_commit: key kept in_progress',
      );
      return;
    }
    const problem = toProblem(err, req.id ?? newId(), this.baseUrl);
    if (isStorableErrorStatus(problem.status) && !state.recordedInTx) {
      try {
        await this.service.complete(state.scope, problem.status, problem.body);
        return;
      } catch (e) {
        this.logger.warn({ err: e }, 'storing business error failed, releasing key');
      }
    }
    // Итог, записанный в транзакции (recordedInTx), release не трогает: удаляются только строки in_progress.
    await this.service.release(state.scope).catch((e: unknown) => this.logger.warn({ err: e }, 'release failed'));
  }
}

function validation(rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: message,
    errors: [{ field: IDEMPOTENCY_KEY_HEADER, message, rule }],
  });
}
