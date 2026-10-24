import { type CanActivate, type ExecutionContext, Inject, Injectable } from '@nestjs/common';
import type { Request } from 'express';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { MUTATING_METHODS, requestRouteTemplate, routeKey } from '../http/route-template.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { type AllowedMutation, READ_ONLY_ALLOWLIST } from './read-only.allowlist.js';

/**
 * Режим «только чтение» (ядро §17.4, §17.7; 11 SEC-119; ADR-083 п. (1)): при `APP_READ_ONLY=true` любая мутация
 * (`POST`/`PUT`/`PATCH`/`DELETE`), пары «метод + шаблон пути» которой нет в перечне, → `503 APP_READ_ONLY`.
 * Глобальный guard, регистрируется первым (до RBAC): проверка не зависит от permission (11 §4.3.1).
 * `GET`/`HEAD` обслуживаются по обычным правам. Перечень прав не выдаёт (ADR-083 п. (4)).
 */
@Injectable()
export class ReadOnlyGuard implements CanActivate {
  private readonly allowed: ReadonlySet<string>;

  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'APP_READ_ONLY'>,
    @Inject(READ_ONLY_ALLOWLIST) allowlist: readonly AllowedMutation[],
  ) {
    this.allowed = new Set(allowlist.map((m) => routeKey(m.method, m.path)));
  }

  canActivate(context: ExecutionContext): boolean {
    if (!this.config.APP_READ_ONLY || context.getType() !== 'http') return true;
    const req = context.switchToHttp().getRequest<Request>();
    const method = req.method.toUpperCase();
    if (!MUTATING_METHODS.has(method)) return true;
    if (this.allowed.has(routeKey(method, requestRouteTemplate(req)))) return true;
    throw new ProblemException('APP_READ_ONLY', {
      detail: 'Включён режим только чтения: изменяющие операции временно недоступны.',
    });
  }
}
