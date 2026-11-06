import {
  Body,
  type CanActivate,
  Controller,
  type ExecutionContext,
  Get,
  Header,
  HttpCode,
  Inject,
  Injectable,
  Param,
  Patch,
  Post,
  Query,
  Req,
  SetMetadata,
  UseGuards,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ApiTags } from '@nestjs/swagger';
import { uuidParam } from '../../admin/users/shared/params.js';
import { AdminStepUpGuard, RequireStepUp } from '../../admin/users/shared/step-up.guard.js';
import type { AuthHttpRequest } from '../../auth/common/request.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { requestRouteTemplate, routeKey } from '../../common/http/route-template.js';
import { requestFingerprint } from '../../common/idempotency/fingerprint.js';
import { IDEMPOTENCY_KEY_HEADER, Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { isUuidV4Lower } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import {
  type KioskTokensDto,
  parseEnrollBody,
  parseReconnectBody,
  parseRevokeBody,
  parseUpdateBody,
  type StoreTabletDto,
  type StoreTabletsListDto,
  StoreTabletsListQuery,
} from './store-tablets.dto.js';
import { type SecretIdempotency, StoreTabletsService } from './store-tablets.service.js';

// ------------------------------------------------------------------------------------------- KIOSK_MODE

const KIOSK_MODE_REQUIRED = 'optomstroy:kiosk-mode-required';

/**
 * Операция существует только при `KIOSK_MODE=true` (08 §4.18 «Планшеты магазина в модуле admin», §2.4; OpenAPI
 * `x-feature-flag: KIOSK_MODE`): подключение и подключение заново. Список, изменение и отключение флага не требуют —
 * путь отката P-002 §23 (ADR-115 п. 28).
 */
export const RequireKioskMode = (): MethodDecorator => SetMetadata(KIOSK_MODE_REQUIRED, true);

/**
 * `KIOSK_MODE=false` → `403 KIOSK_DISABLED` («подключение недоступно»; 08 §2.4). Guard контроллера: после Auth (401)
 * и RBAC (403 FORBIDDEN) и **до** step-up — администратор не подтверждает PIN ради операции, которой нет; ключ
 * идемпотентности при этом не захватывается (как guard модуля заявок на возврат, 08 §2.4 «этап G» (1)).
 */
@Injectable()
export class KioskModeRequiredGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'KIOSK_MODE'>,
  ) {}

  canActivate(context: ExecutionContext): boolean {
    if (context.getType() !== 'http') return true;
    if (this.reflector.get<boolean | undefined>(KIOSK_MODE_REQUIRED, context.getHandler()) !== true) return true;
    if (this.config.KIOSK_MODE) return true;
    throw new ProblemException('KIOSK_DISABLED', {
      detail: 'Подключение планшета недоступно: режим «Планшет магазина» выключен.',
    });
  }
}

// ------------------------------------------------------------------------------------------- Idempotency-Key

const KEY_IN_SERVICE = 'optomstroy:kiosk-idempotency-in-service';
const KEY_IN_SERVICE_STATE = Symbol.for('optomstroy.kiosk.idempotency-in-service');

/**
 * `Idempotency-Key` обязателен, но ответ несёт токены планшета и аварийный код (08 §2.7 «Подключение и подключение
 * заново планшета»; 11 SEC-141 п. 5): общий `IdempotencyInterceptor` сохранил бы тело ответа в `idempotency_keys`,
 * поэтому ключ обрабатывает сервис — в хранилище только идентификаторы, повтор выдаёт новые токены и новый код.
 */
export const SecretResponseIdempotency = (): MethodDecorator => SetMetadata(KEY_IN_SERVICE, true);

function idempotencyKeyInvalid(rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: message,
    errors: [{ field: IDEMPOTENCY_KEY_HEADER, message, rule }],
  });
}

/**
 * Снимает `Idempotency-Key` с запроса до глобального `IdempotencyInterceptor` (он выполняется после guard-ов и без
 * заголовка ничего не хранит — как `IgnoreIdempotencyKeyGuard` аварийного кода входа) и передаёт ключ сервису:
 * нет ключа → `400 idempotency_key_required`, не UUID v4 → `400 idempotency_key_format` (08 §2.7). Скоуп и отпечаток —
 * те же, что у интерсептора: `routeKey(method, шаблон маршрута)`, `requestFingerprint(params, body)`. Стоит после
 * step-up: `403 STEP_UP_REQUIRED` ключ не захватывает, повтор с токеном идёт с тем же ключом.
 */
@Injectable()
export class SecretResponseIdempotencyGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    if (context.getType() !== 'http') return true;
    if (this.reflector.get<boolean | undefined>(KEY_IN_SERVICE, context.getHandler()) !== true) return true;
    const req = context.switchToHttp().getRequest<RequestWithContext & { params?: unknown; body?: unknown }>();
    const raw = req.headers['idempotency-key'];
    delete req.headers['idempotency-key'];
    const key = typeof raw === 'string' ? raw : undefined;
    if (key === undefined || key === '') {
      if (Array.isArray(raw)) {
        throw idempotencyKeyInvalid('idempotency_key_format', 'Idempotency-Key — UUID v4 в нижнем регистре.');
      }
      throw idempotencyKeyInvalid('idempotency_key_required', 'Заголовок Idempotency-Key обязателен.');
    }
    if (!isUuidV4Lower(key)) {
      throw idempotencyKeyInvalid('idempotency_key_format', 'Idempotency-Key — UUID v4 в нижнем регистре.');
    }
    const state: SecretIdempotency = {
      key,
      route: routeKey(req.method ?? 'POST', requestRouteTemplate(req)),
      fingerprint: requestFingerprint(req.params ?? {}, req.body),
    };
    (req as unknown as { [KEY_IN_SERVICE_STATE]?: SecretIdempotency })[KEY_IN_SERVICE_STATE] = state;
    return true;
  }
}

/** Ключ запроса, снятый `SecretResponseIdempotencyGuard`; нет — ошибка конфигурации маршрута. */
export function secretIdempotencyOf(req: object): SecretIdempotency {
  const state = (req as { [KEY_IN_SERVICE_STATE]?: SecretIdempotency })[KEY_IN_SERVICE_STATE];
  if (!state) throw new ProblemException('INTERNAL');
  return state;
}

// ------------------------------------------------------------------------------------------- контроллер

/**
 * Планшеты магазина в модуле `admin` (08 §4.18.11–§4.18.14; OpenAPI 1.3.0 `kiosk_tablets_*`, тег `kiosk`; SCR-54,
 * FLOW-043; ADR-115; права — 11 №77 `kiosk.read` (`admin`, `owner`), №78 `kiosk.manage` (только `admin`)).
 * Порядок проверок: Auth (401) → RBAC (403 FORBIDDEN, deny by default; токен планшета — `kiosk_closed_list`) →
 * `KIOSK_MODE` (403 KIOSK_DISABLED; только подключение) → step-up `kiosk.manage` (403 STEP_UP_REQUIRED, до раскрытия
 * существования цели) → `Idempotency-Key` → тело (400) → цель и склад (404). Лимит — RL-ADMIN (`/admin/*`).
 * `KIOSK_MODE` и `Idempotency-Key` с ответом-секретом — у подключения и подключения заново (`…/reconnect`).
 */
@ApiTags('kiosk')
@Controller('admin/store-tablets')
@UseGuards(KioskModeRequiredGuard, AdminStepUpGuard, SecretResponseIdempotencyGuard)
export class AdminStoreTabletsController {
  constructor(private readonly service: StoreTabletsService) {}

  /** `GET /admin/store-tablets` (08 §4.18.12): работает и при `KIOSK_MODE=false`; аудит не пишется. */
  @Get()
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.read')
  list(@Query() q: StoreTabletsListQuery): Promise<StoreTabletsListDto> {
    return this.service.list(q.status);
  }

  /** `POST /admin/store-tablets` (08 §4.18.11): подключить это устройство; ответ — `KioskTokens` (один раз). */
  @Post()
  @HttpCode(201)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.manage')
  @RequireKioskMode()
  @RequireStepUp('kiosk.manage')
  @SecretResponseIdempotency()
  enroll(@Req() req: AuthHttpRequest, @Body() raw: unknown): Promise<KioskTokensDto> {
    const body = parseEnrollBody(raw);
    return this.service.enroll(req, body, secretIdempotencyOf(req));
  }

  /** `PATCH /admin/store-tablets/{id}` (08 §4.18.13): имя и склад; без step-up; и при `KIOSK_MODE=false`. */
  @Patch(':id')
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.manage')
  @Idempotent({ required: false })
  update(@Req() req: AuthHttpRequest, @Param('id') id: string, @Body() raw: unknown): Promise<StoreTabletDto> {
    const tabletId = uuidParam(id);
    return this.service.update(req, tabletId, parseUpdateBody(raw));
  }

  /**
   * `POST /admin/store-tablets/{id}/reconnect` (08 §4.18.15): подключить заново тот же планшет с самого устройства;
   * тело — `{}`; ответ 200 — `KioskTokens` с новым аварийным кодом (один раз). При `KIOSK_MODE=false` — 403.
   */
  @Post(':id/reconnect')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.manage')
  @RequireKioskMode()
  @RequireStepUp('kiosk.manage')
  @SecretResponseIdempotency()
  reconnect(@Req() req: AuthHttpRequest, @Param('id') id: string, @Body() raw: unknown): Promise<KioskTokensDto> {
    const tabletId = uuidParam(id);
    parseReconnectBody(raw);
    return this.service.reconnect(req, tabletId, secretIdempotencyOf(req));
  }

  /** `POST /admin/store-tablets/{id}/revoke` (08 §4.18.14): отключить; step-up; и при `KIOSK_MODE=false`. */
  @Post(':id/revoke')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('kiosk.manage')
  @RequireStepUp('kiosk.manage')
  @Idempotent({ required: false })
  revoke(@Req() req: AuthHttpRequest, @Param('id') id: string, @Body() raw: unknown): Promise<StoreTabletDto> {
    const tabletId = uuidParam(id);
    return this.service.revoke(req, tabletId, parseRevokeBody(raw));
  }
}
