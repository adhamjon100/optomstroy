import {
  type CanActivate,
  createParamDecorator,
  type ExecutionContext,
  Inject,
  Injectable,
  SetMetadata,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { AppPinsRepository } from '../../auth/pin/app-pins.repository.js';
import { StepUpService, type VerifiedStepUp } from '../../auth/step-up/step-up.service.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import {
  OTP_SESSION_STEP_UP_WINDOW_MS,
  type ProfileStepUpOperation,
  STEP_UP_TOKEN_HEADER,
} from '../profile.constants.js';

/**
 * Исключения из step-up (без `X-Step-Up-Token`), когда владение номером только что доказано OTP:
 * - `otp_session_window` — сессия создана по OTP не более 15 мин назад (09 §9.5 п. 3: включение биометрии сразу
 *   после входа/регистрации);
 * - `first_pin_otp_window` — то же и PIN ещё не установлен (08 §4.3.5: первый PIN сотрудника по приглашению;
 *   09 §7.3: клиент, выбравший при регистрации только биометрию).
 */
export type StepUpExemption = 'otp_session_window' | 'first_pin_otp_window';

export interface StepUpRequirement {
  readonly operation: ProfileStepUpOperation;
  /** Step-up нужен только для части запросов (например, отзыв `personal_data`); по умолчанию — всегда. */
  readonly when?: (req: RequestWithContext) => boolean;
  readonly exemption?: StepUpExemption;
}

export const PROFILE_STEP_UP_META = 'optomstroy:profile-step-up';

/**
 * Маршрут требует step-up профиля (08 §2.12). Проверка — в guard, до валидации тела (приоритет 403 → 400, 08 §2.4);
 * сам токен проверяет `StepUpService.verify` модуля auth (sub, sid, deviceId, pv, scope, method, denylist).
 */
export const RequireStepUp = (requirement: StepUpRequirement): MethodDecorator =>
  SetMetadata(PROFILE_STEP_UP_META, requirement);

/** Результат проверки step-up для обработчика (аудит `step_up_method`). */
export interface StepUpOutcome {
  readonly required: boolean;
  /** `null` — step-up не требовался или выполнен исключением (OTP-вход ≤ 15 мин). */
  readonly proof: VerifiedStepUp | null;
  readonly exemptBy?: StepUpExemption;
}

const OUTCOME = Symbol.for('optomstroy.profile.stepUpOutcome');
type Carrier = RequestWithContext & { [OUTCOME]?: StepUpOutcome };

export function stepUpOutcomeOf(req: RequestWithContext): StepUpOutcome {
  return (req as Carrier)[OUTCOME] ?? { required: false, proof: null };
}

export const StepUpResult = createParamDecorator((_: unknown, ctx: ExecutionContext): StepUpOutcome =>
  stepUpOutcomeOf(ctx.switchToHttp().getRequest()),
);

function headerValue(req: RequestWithContext, name: string): string | undefined {
  const v = req.headers[name];
  const s = Array.isArray(v) ? (v.length === 1 ? v[0] : undefined) : v;
  return typeof s === 'string' && s.trim() !== '' ? s.trim() : undefined;
}

/**
 * Guard step-up профиля: выполняется после глобальных ReadOnly → Auth → RBAC, до pipes. Решение об исключении
 * принимает по данным БД (сессия `sid`, наличие `app_pins`).
 */
@Injectable()
export class ProfileStepUpGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly stepUp: StepUpService,
    private readonly sessions: SessionsRepository,
    private readonly pins: AppPinsRepository,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const requirement = this.reflector.get<StepUpRequirement | undefined>(PROFILE_STEP_UP_META, context.getHandler());
    if (!requirement) return true;
    const req = context.switchToHttp().getRequest<Carrier>();
    if (requirement.when && !requirement.when(req)) {
      req[OUTCOME] = { required: false, proof: null };
      return true;
    }
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal))
      throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (requirement.exemption) {
      const eligible = requirement.exemption === 'otp_session_window' || !(await this.pins.exists(principal.userId));
      if (eligible) {
        const session = await this.sessions.findById(principal.sessionId);
        const fresh =
          session !== undefined &&
          session.kind === 'standard' &&
          // OTP-сессия или вход по аварийному коду (09 §6.13 п. 3: «step-up считается выполненным 15 мин», как §9.5)
          (session.amr.includes('sms') || session.amr.includes('admin_code')) &&
          this.clock.now().getTime() - session.issuedAt.getTime() <= OTP_SESSION_STEP_UP_WINDOW_MS;
        if (fresh) {
          req[OUTCOME] = { required: true, proof: null, exemptBy: requirement.exemption };
          return true;
        }
      }
    }
    const proof = await this.stepUp.verify(headerValue(req, STEP_UP_TOKEN_HEADER), principal, requirement.operation);
    req[OUTCOME] = { required: true, proof };
    return true;
  }
}
