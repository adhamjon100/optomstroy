import { type DynamicModule, Module } from '@nestjs/common';
import { AuditModule } from '../common/audit/audit.module.js';
import { AuthCoreModule } from '../common/auth/auth-core.module.js';
import { CryptoModule } from '../common/crypto/crypto.module.js';
import { RateLimitModule } from '../common/rate-limit/rate-limit.module.js';
import { SmsGatewayModule } from '../integrations/sms/sms.module.js';
import { SMS_DELIVERY_LISTENER } from '../notifications/sms/sms-delivery.listener.js';
import { SmsNotificationsModule } from '../notifications/sms/sms-notifications.module.js';
import { UsersModule } from '../users/users.module.js';
import { AuthPolicyService } from './common/auth-policy.js';
import { AuthHttpRateLimiter } from './common/http-rate-limits.js';
import { EmergencyLoginService } from './login/emergency-login.service.js';
import { InvitationsReader } from './login/invitations.reader.js';
import { LoginService } from './login/login.service.js';
import { MeSnapshotBuilder } from './login/me-snapshot.js';
import { RegistrationTokenService } from './login/registration-token.service.js';
import { EmergencyChallengesRepository } from './otp/emergency-challenges.repository.js';
import { OtpChallengesRepository } from './otp/otp-challenges.repository.js';
import { OtpCircuitBreaker } from './otp/otp-circuit-breaker.js';
import { OtpController } from './otp/otp.controller.js';
import { OTP_PROVIDER, SmsOtpProvider } from './otp/otp.provider.js';
import { OtpService } from './otp/otp.service.js';
import { OtpSmsDeliveryListener, QueuedSmsOtpProvider } from './otp/queued-sms-otp.provider.js';
import { SmsOutboxRepository } from './otp/sms-outbox.repository.js';
import { AppPinsRepository } from './pin/app-pins.repository.js';
import { PinVerifier } from './pin/pin-verifier.service.js';
import { RefreshService } from './sessions/refresh.service.js';
import { SessionActivityGuard } from './sessions/session-activity.guard.js';
import { SessionIssuer } from './sessions/session-issuer.service.js';
import { SessionStore } from './sessions/session-store.js';
import { SessionsController } from './sessions/sessions.controller.js';
import { SessionsService } from './sessions/sessions.service.js';
import { StepUpController } from './step-up/step-up.controller.js';
import { StepUpGuard } from './step-up/step-up.guard.js';
import { StepUpTokenVerifier } from './step-up/step-up-token.verifier.js';
import { StepUpService } from './step-up/step-up.service.js';

/**
 * Модуль D-06 `auth` (RM-D-001, RM-D-003, RM-D-014 — статус доставки, RM-D-017 — ветвление входа): OTP-вход,
 * сессии и refresh-ротация, разблокировка, step-up. Общий фундамент (common/auth, common/crypto, common/audit,
 * common/rate-limit, src/users — все глобальные) подключается здесь, чтобы модуль был самодостаточен; порт
 * `SmsGateway` — integrations/sms. Глобальные guard'ы app.module.ts (владелец каркаса): ReadOnlyGuard →
 * `AUTH_APP_GUARD` → `AUTH_SESSION_ACTIVITY_GUARD` → RbacGuard.
 *
 * Экспорт для модулей registration/profile/admin: StepUpService/StepUpGuard (`@RequireStepUp`),
 * RegistrationTokenService (погашение `registration_token`), SessionIssuer, PinVerifier, AppPinsRepository,
 * OtpService, SessionActivityGuard (`forgetPin`).
 */
@Module({
  imports: [CryptoModule, AuditModule, AuthCoreModule, RateLimitModule, UsersModule, SmsGatewayModule],
  controllers: [OtpController, SessionsController, StepUpController],
  providers: [
    AuthPolicyService,
    AuthHttpRateLimiter,
    OtpChallengesRepository,
    EmergencyChallengesRepository,
    EmergencyLoginService,
    SmsOutboxRepository,
    OtpCircuitBreaker,
    SmsOtpProvider,
    { provide: OTP_PROVIDER, useExisting: SmsOtpProvider },
    OtpService,
    AppPinsRepository,
    PinVerifier,
    SessionStore,
    SessionIssuer,
    RefreshService,
    SessionsService,
    InvitationsReader,
    RegistrationTokenService,
    MeSnapshotBuilder,
    LoginService,
    StepUpTokenVerifier,
    StepUpService,
    StepUpGuard,
    SessionActivityGuard,
  ],
  exports: [
    AuthPolicyService,
    AuthHttpRateLimiter,
    OtpService,
    OTP_PROVIDER,
    AppPinsRepository,
    PinVerifier,
    SessionStore,
    SessionIssuer,
    RegistrationTokenService,
    StepUpTokenVerifier,
    StepUpService,
    StepUpGuard,
    SessionActivityGuard,
  ],
})
export class AuthModule {
  /**
   * Вариант доставки OTP через очередь pos-worker (RM-D-002, notifications/sms): `OTP_PROVIDER` →
   * QueuedSmsOtpProvider (`sms_outbox` + задание `sms.send` в транзакции выпуска кода), порт
   * `SMS_DELIVERY_LISTENER` → OtpSmsDeliveryListener (итог `failed` → `failed_delivery`). Модуль становится
   * глобальным, чтобы порт был виден SmsNotificationsModule. Требует JobsModule (PgBossService) и обработчиков
   * `sms.send` в pos-worker. По умолчанию (`AuthModule`) — отправка процессом pos-api через `SmsGateway`.
   */
  static withQueuedSms(): DynamicModule {
    return {
      module: AuthModule,
      global: true,
      imports: [SmsNotificationsModule],
      providers: [
        QueuedSmsOtpProvider,
        OtpSmsDeliveryListener,
        { provide: OTP_PROVIDER, useExisting: QueuedSmsOtpProvider },
        { provide: SMS_DELIVERY_LISTENER, useExisting: OtpSmsDeliveryListener },
      ],
      exports: [SMS_DELIVERY_LISTENER, OtpSmsDeliveryListener],
    };
  }
}
