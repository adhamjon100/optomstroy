import { Module } from '@nestjs/common';
import { KioskTabletReader } from './common/kiosk-tablet.reader.js';
import { KioskLifecycleModule } from './lifecycle/kiosk-lifecycle.module.js';
import { KioskOpsModule } from './ops/kiosk-ops.module.js';
import { KioskOrdersModule } from './orders/kiosk-orders.module.js';
import { KioskOtpModule } from './otp/kiosk-otp.module.js';

/**
 * Модуль `kiosk` — режим «Планшет магазина» (06 §7.4, MOD-030; P-002 §8, §12; ADR-115). Вне перечня модулей D-06
 * (подключается в AppModule через `EXTRA_API_MODULES`). Состав: `common` — закрытый список маршрутов
 * (kiosk-routes.ts), глобальный `KioskAccessGuard` (регистрируется в `GLOBAL_PROVIDERS` app.module.ts между
 * SessionActivityGuard и RbacGuard) и чтение планшета запроса; `lifecycle`, `otp`, `orders`, `ops` — подмодули.
 * Другим доменным модулям сервисов не экспортирует; `KioskTabletReader` и сервисы `ops` (отметка связи, алерт «вне сети
 * магазина») экспортируются только для guard-а корня приложения. `common/**` этот модуль не импортирует
 * (eslint.config.mjs, `MODULES`).
 */
@Module({
  imports: [KioskLifecycleModule, KioskOtpModule, KioskOrdersModule, KioskOpsModule],
  providers: [KioskTabletReader],
  exports: [KioskTabletReader, KioskOpsModule],
})
export class KioskModule {}
