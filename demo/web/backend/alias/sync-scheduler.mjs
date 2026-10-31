// Подмена dist/sync/scheduler/sync-scheduler.js (WP-B2, continuations-audit.md): тот же SyncScheduler, но
// периодический пересчёт расписаний (startRefresh, setInterval каждые scheduleRefreshMs = 60 с) выполняется
// «единицей работы» kind 'job' (alias/work-gate.mjs): таймер — самостоятельный вход в бэкенд, его операторы
// (настройки, upsert расписаний pg-boss) не перемежаются с запросами приложения. Первый apply() из
// WorkerRuntime.start (инициализация, до ready) не меняется.
import * as original from '@pos-api-dist/sync/scheduler/sync-scheduler.js';
import { runTimerUnit } from './work-gate.mjs';

export const { IMAGES_GC_CRON, OUTBOX_RECONCILE_CRON, OUTBOX_UNLOCK_CRON, SyncScheduler } = original;

if (!SyncScheduler.prototype.__posGateWrapped) {
  // Тело — как в оригинале (sync-scheduler.ts startRefresh), вызов apply() — единицей работы.
  SyncScheduler.prototype.startRefresh = function startRefresh() {
    this.timer = setInterval(() => {
      runTimerUnit('scheduler.refresh', () => this.apply()).catch((err) => this.log.error({ err }, 'scheduler.refresh_failed'));
    }, this.cfg.scheduleRefreshMs);
    this.timer.unref?.();
  };
  SyncScheduler.prototype.__posGateWrapped = true;
}
