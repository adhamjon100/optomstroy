import { Module } from '@nestjs/common';
import { AuthModule } from '../../auth/auth.module.js';
import { CustomerMatchingModule } from '../../customers/matching/customer-matching.module.js';
import { KioskOrdersController } from './kiosk-orders.controller.js';
import { KioskOrderService } from './kiosk-order.service.js';

/**
 * Подмодуль `kiosk/orders` (06 MOD-030; ADR-115): заявка с планшета `POST /kiosk/orders` в три шага и номер по ключу
 * `GET /kiosk/orders?idempotencyKey=` (08 §4.25.2, §4.25.3). Заказ создаёт модуль `orders` через порт
 * `KIOSK_ORDER_PORT` (`common/ports`; второй реализации создания заказа нет), токен предпросмотра сверяет порт
 * `CART_READER` — оба из глобального `SalesPortsModule`. Проверка кода — `OtpService` модуля `auth` (как
 * `kiosk/otp`); чтение и погашение строки кода — свой экземпляр `OtpChallengesRepository` внутри сервиса (не
 * провайдер модуля — как в `kiosk/lifecycle`). Поиск карточки 1С по номеру — `KioskCustomerMatcher`
 * модуля `customers/matching` (`onec: 'auto'`, как у `CustomersModule`). Контроллер — `@ApiTags('kiosk')`. Другим
 * модулям ничего не экспортирует.
 */
@Module({
  imports: [AuthModule, CustomerMatchingModule.forRoot({ onec: 'auto' })],
  controllers: [KioskOrdersController],
  providers: [KioskOrderService],
})
export class KioskOrdersModule {}
