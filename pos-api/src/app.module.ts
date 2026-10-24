import { type DynamicModule, type MiddlewareConsumer, Module, type NestModule, RequestMethod } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { DestinationStream } from 'pino';
import { AdminModule } from './admin/admin.module.js';
import { AuthModule } from './auth/auth.module.js';
import { AUTH_SESSION_ACTIVITY_GUARD } from './auth/sessions/session-activity.guard.js';
import { CartModule } from './cart/cart.module.js';
import { CatalogModule } from './catalog/catalog.module.js';
import { AppVersionMiddleware } from './common/app-version/app-version.middleware.js';
import { AppVersionModule } from './common/app-version/app-version.module.js';
import { AuditModule } from './common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from './common/auth/auth-core.module.js';
import type { AppConfig } from './common/config/app-config.js';
import { ConfigModule } from './common/config/config.module.js';
import { CryptoModule } from './common/crypto/crypto.module.js';
import { DatabaseModule } from './common/db/database.module.js';
import { IdempotencyInterceptor } from './common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from './common/idempotency/idempotency.module.js';
import { JobsModule } from './common/jobs/jobs.module.js';
import { LoggingModule } from './common/logging/logging.module.js';
import { ProblemDetailsFilter } from './common/problem-details/problem-details.filter.js';
import { RateLimitModule } from './common/rate-limit/rate-limit.module.js';
import { RbacGuard } from './common/rbac/rbac.guard.js';
import { RbacModule } from './common/rbac/rbac.module.js';
import {
  type AllowedMutation,
  DEFAULT_READ_ONLY_ALLOWLIST,
  READ_ONLY_ALLOWLIST,
} from './common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from './common/read-only/read-only.guard.js';
import { SettingsModule } from './common/settings/settings.module.js';
import { createValidationPipe } from './common/validation/validation.js';
import { CustomersModule } from './customers/customers.module.js';
import { HealthModule } from './health/health.module.js';
import { NotificationsModule } from './notifications/notifications.module.js';
import { DocumentsModule } from './orders/documents/documents.module.js';
import { OrdersModule } from './orders/orders.module.js';
import { PaymentsModule } from './payments/payments.module.js';
import { ProfileModule } from './profile/profile.module.js';
import { RegistrationModule } from './registration/registration.module.js';
import { ReturnsModule } from './returns/returns.module.js';
import { SalesPortsModule } from './sales-domain/sales-ports.module.js';
import { PublicSettingsModule } from './settings/public-settings.module.js';
import { HttpRateLimitModule } from './common/rate-limit/http-rate-limit.js';
import { SyncModule } from './sync/sync.module.js';
import { TransactionsModule } from './transactions/transactions.module.js';
import { UsersModule } from './users/users.module.js';

/**
 * Модули D-06 (06 §7.4; 13 RM-C-005): модульный монолит, pos-worker — тот же код с ролью воркера (D-45).
 * `auth` — с доставкой OTP через очередь pos-worker (`sms_outbox` + `sms.send` в транзакции выпуска кода; 09 §6.8,
 * 06 §7.5; INT-01): процесс API SMSPro не вызывает.
 */
export const DOMAIN_MODULES = [
  AuthModule.withQueuedSms(),
  RegistrationModule,
  ProfileModule,
  CatalogModule,
  CartModule,
  OrdersModule,
  PaymentsModule,
  CustomersModule,
  TransactionsModule,
  ReturnsModule,
  SyncModule,
  AdminModule,
  NotificationsModule,
  HealthModule,
];

/**
 * Модули вне перечня D-06, подключаемые к API: публичные настройки `GET /settings/public` (08 §4.23; RM-D-015,
 * D_spec_questions LNK-11 — путь `src/settings`).
 */
export const EXTRA_API_MODULES = [PublicSettingsModule];

/**
 * Этап F (основа backend): глобальный модуль портов межмодульных вызовов (`SalesPortsModule` — DI-токены
 * `common/ports`, позднее связывание реализаций; 06 §7.4) и документы заказа (`DocumentsModule` — часть `orders`,
 * отдельный Nest-модуль для параллельной разработки).
 */
export const SALES_F_MODULES = [SalesPortsModule, DocumentsModule];

export interface AppModuleOptions {
  /** Перехват логов (тесты). */
  readonly logStream?: DestinationStream;
  /** Дополнительные модули (тестовые контроллеры e2e/unit). */
  readonly extraModules?: readonly (DynamicModule | (new () => unknown))[];
  /**
   * Перечень мутаций, разрешённых при APP_READ_ONLY=true. По умолчанию — пустой (ADR-083 «Предложено»: действует
   * 11 SEC-119 «все мутации → 503»; ревью C-MJ-03). Тесты подставляют ADR_083_ALLOWED_MUTATIONS явно.
   */
  readonly readOnlyAllowlist?: readonly AllowedMutation[];
}

/** Общая инфраструктура common/*. */
export function commonImports(config: AppConfig, options: AppModuleOptions = {}): DynamicModule['imports'] {
  return [
    ConfigModule.forRoot(config),
    LoggingModule.forRoot(config, options.logStream),
    DatabaseModule,
    SettingsModule,
    JobsModule,
    RbacModule,
    IdempotencyModule,
    AppVersionModule,
    // Общий фундамент авторизации этапа D (глобальные): секреты/HMAC/PIN-хэш, аудит, JWT + AuthGuard, лимиты, users.
    CryptoModule,
    AuditModule,
    AuthCoreModule,
    RateLimitModule,
    UsersModule,
  ];
}

/**
 * Глобальные guard/interceptor/filter/pipe. Порядок guard'ов (Nest применяет APP_GUARD в порядке регистрации):
 * read-only (ADR-083) → аутентификация (common/auth AuthGuard, 08 §2.2) → ограничение сессии без PIN и активность
 * сессии (auth SessionActivityGuard, 08 API-181) → RBAC (11 §4.3.1). 401 всегда раньше 403 (08 §2.4).
 */
export const GLOBAL_PROVIDERS = [
  { provide: APP_GUARD, useClass: ReadOnlyGuard },
  AUTH_APP_GUARD,
  AUTH_SESSION_ACTIVITY_GUARD,
  { provide: APP_GUARD, useClass: RbacGuard },
  { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
  { provide: APP_FILTER, useClass: ProblemDetailsFilter },
  { provide: APP_PIPE, useFactory: createValidationPipe },
];

@Module({})
export class AppModule implements NestModule {
  static forRoot(config: AppConfig, options: AppModuleOptions = {}): DynamicModule {
    return {
      module: AppModule,
      imports: [
        ...(commonImports(config, options) ?? []),
        ...DOMAIN_MODULES,
        ...SALES_F_MODULES,
        ...EXTRA_API_MODULES,
        // RL-READ / RL-SEARCH / RL-CART (08 §2.9, memory; ревью E-security-2).
        HttpRateLimitModule,
        ...(options.extraModules ?? []),
      ],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: options.readOnlyAllowlist ?? DEFAULT_READ_ONLY_ALLOWLIST },
        ...GLOBAL_PROVIDERS,
      ],
    };
  }

  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(AppVersionMiddleware).forRoutes({ path: '{*splat}', method: RequestMethod.ALL });
  }
}
