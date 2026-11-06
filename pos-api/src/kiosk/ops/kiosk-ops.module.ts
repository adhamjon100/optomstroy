import { Module } from '@nestjs/common';
import { KioskAlertsService, KioskPresenceService } from './kiosk-alerts.service.js';

/**
 * Подмодуль `kiosk/ops` (06 MOD-030; ADR-115): отметка связи планшета `last_seen_at`, `last_app_version`,
 * `lock_task_enabled` (`KioskPresenceService`, не чаще раза в 60 с) и сигналы администратору (11 §6.2;
 * `KioskAlertsService`: сразу — запрос вне `KIOSK_ALLOWED_CIDRS`, по расписанию `kiosk.alerts` в pos-worker — всплеск
 * кодов, лимит кодов, «не на связи», конец подключения, версия ниже рекомендуемой). Оба сервиса нужны глобальному
 * `KioskAccessGuard` корня приложения — модуль экспортирует их через `KioskModule`. Сброс планшета `POST /kiosk/reset` —
 * контроллер модуля `cart` (06 §7.4), не здесь. Зависимости — глобальные модули `common` (БД, часы, аудит, настройки,
 * политика версий, порт уведомлений, pg-boss).
 */
@Module({
  providers: [KioskPresenceService, KioskAlertsService],
  exports: [KioskPresenceService, KioskAlertsService],
})
export class KioskOpsModule {}
