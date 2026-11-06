import { Module } from '@nestjs/common';
import { AdminSharedModule } from '../../admin/users/shared/admin-shared.module.js';
import { AuthModule } from '../../auth/auth.module.js';
import { CartModule } from '../../cart/cart.module.js';
import { IgnoreIdempotencyKeyGuard } from '../../common/idempotency/ignore-idempotency-key.guard.js';
import {
  AdminStoreTabletsController,
  KioskModeRequiredGuard,
  SecretResponseIdempotencyGuard,
} from './admin-store-tablets.controller.js';
import { KioskExitController } from './kiosk-exit.controller.js';
import { KioskExitService } from './kiosk-exit.service.js';
import { StoreTabletsRepository } from './store-tablets.repository.js';
import { StoreTabletsService } from './store-tablets.service.js';

/**
 * Подмодуль `kiosk/lifecycle` (06 MOD-030; ADR-115): подключение, список, изменение, отключение и подключение заново
 * планшета `/admin/store-tablets*` (08 §4.18.11–§4.18.15; `AdminStoreTabletsController`, `@ApiTags('kiosk')`) и
 * аварийный выход со связью `POST /kiosk/exit` (08 §4.25.5; `KioskExitController`). `401 KIOSK_REVOKED` для сессий,
 * отозванных этим модулем с `kiosk_revoked`, отвечают AuthGuard (common/auth) и `POST /auth/refresh` (auth/sessions).
 * Зависимости: `auth` — `SessionIssuer` (сессия планшета) и `SessionStore` (повтор подключения); проверка
 * `X-Step-Up-Token` — `AdminStepUpGuard` админ-раздела (`AdminSharedModule`); погашение кодов `kiosk_order` при
 * отключении, подключении заново и выходе — экземпляр `OtpChallengesRepository` внутри сервисов (класс без состояния,
 * только `DRIZZLE`; `AuthModule` его не экспортирует, провайдером модуля не регистрируется); закрытие корзины
 * технического пользователя при подключении заново — `KioskCartCloser` модуля `cart` (MOD-024: `carts.status` пишет
 * только `cart`). Сервисов другим модулям не экспортирует.
 */
@Module({
  imports: [AuthModule, AdminSharedModule, CartModule],
  controllers: [AdminStoreTabletsController, KioskExitController],
  providers: [
    StoreTabletsService,
    StoreTabletsRepository,
    KioskExitService,
    KioskModeRequiredGuard,
    SecretResponseIdempotencyGuard,
    IgnoreIdempotencyKeyGuard,
  ],
})
export class KioskLifecycleModule {}
