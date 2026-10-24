-- 0018_audit_system_events.sql — системные события аудита D-36 (этап G, RM-G-006; агент G-be-admin-reports).
--
-- Основание: 11 §7.2 / §7.2.1 (словарь `audit_logs.action`, владелец — ядро §18.1): `sync.run.finished`,
-- `sync.run.failed`, `sync.prices.applied`, `sync.stock.applied` (применение данных 1С фиксируется агрегированно,
-- 07 §9.2 «prices, stock_balances — построчных триггеров нет»; ядро §17.2, D-36), `outbox.confirmed`,
-- `outbox.rejected`, `outbox.dead`, `outbox.cancelled` (08 §4.21.3; автомат outbox 07 §6.5, ядро §22.1).
-- До этой миграции события не писались ни приложением, ни БД (проверка — test/admin/audit-coverage.admin-spec.ts).
--
-- Решение (docs/stages/G_spec_questions.md, GQ-ADM-03): события пишутся триггерами уровня БД (`level = 'db'`) на
-- переходах статуса `sync_runs` и `onec_outbox` — так они не зависят от пути завершения прогона/задачи (планировщик,
-- ручной запуск, план обмена, полная загрузка, диспетчер outbox, ручная привязка) и не могут быть пропущены кодом.
-- Состав `after` — без ПДн и без текстов ошибок 1С (05 SYNC-039): сущность, режим, счётчики, коды.
-- Хэш-цепочку (`chain_seq`, `prev_hash`, `row_hash`) по-прежнему вычисляет `trg_audit_logs_chain` (0001, 07 §9.3).
--
-- Идемпотентно: CREATE OR REPLACE FUNCTION / TRIGGER (повторное применение — 0 изменений). Новых таблиц, столбцов и
-- прав нет (запись в `audit_logs` — INSERT роли pos_app, 0001 §11.6).

BEGIN;

-- Запись системного события уровня БД: контекст из SET LOCAL app.* (если задан), уровень важности — явно.
CREATE OR REPLACE FUNCTION audit_system_write(p_action text, p_entity_type text, p_entity_id uuid, p_onec_ref uuid,
                                              p_after jsonb, p_result text, p_severity text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_role_txt text := audit_guc('app.actor_role');
        v_role role_code;
BEGIN
  IF v_role_txt IS NOT NULL AND v_role_txt = ANY (enum_range(NULL::role_code)::text[]) THEN
    v_role := v_role_txt::role_code;
  END IF;
  INSERT INTO audit_logs (level, actor_user_id, actor_role, session_id, device_id, ip, request_id,
                          action, entity_type, entity_id, onec_ref, before, after, result, severity)
  VALUES ('db', audit_guc_uuid('app.actor_id'), v_role, audit_guc_uuid('app.session_id'),
          audit_guc_uuid('app.device_id'), audit_guc_inet('app.ip'), audit_guc('app.request_id'),
          p_action, p_entity_type, p_entity_id, p_onec_ref, NULL, audit_mask_pii(p_after), p_result, p_severity);
END $$;

-- Счётчик `sync_runs.counts` (05 SYNC-037: fetched/inserted/updated/skipped/markedDeleted/errors); не число → 0.
CREATE OR REPLACE FUNCTION sync_run_count(p_counts jsonb, p_key text) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p_counts -> p_key) = 'number' THEN floor((p_counts ->> p_key)::numeric)::bigint
              ELSE 0 END
$$;

-- sync_runs: running/queued → success|partial → `sync.run.finished` (+ `sync.prices.applied` / `sync.stock.applied`
-- при изменённых строках цен/остатков); → failed → `sync.run.failed`.
CREATE OR REPLACE FUNCTION sync_runs_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_after jsonb;
        v_changed bigint;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('success', 'partial', 'failed') THEN
    RETURN NULL;
  END IF;
  v_after := jsonb_build_object(
    'entity', NEW.entity, 'mode', NEW.mode, 'trigger', NEW."trigger", 'status', NEW.status,
    'fetched', sync_run_count(NEW.counts, 'fetched'), 'inserted', sync_run_count(NEW.counts, 'inserted'),
    'updated', sync_run_count(NEW.counts, 'updated'), 'markedDeleted', sync_run_count(NEW.counts, 'markedDeleted'),
    'errors', sync_run_count(NEW.counts, 'errors'), 'durationMs', NEW.duration_ms);
  IF NEW.status = 'failed' THEN
    PERFORM audit_system_write('sync.run.failed', 'sync_runs', NEW.id, NULL, v_after, 'error', 'warning');
    RETURN NULL;
  END IF;
  PERFORM audit_system_write('sync.run.finished', 'sync_runs', NEW.id, NULL, v_after, 'ok', 'info');
  IF NEW.entity IN ('prices', 'stock') THEN
    v_changed := sync_run_count(NEW.counts, 'inserted') + sync_run_count(NEW.counts, 'updated')
               + sync_run_count(NEW.counts, 'markedDeleted');
    IF v_changed > 0 THEN
      PERFORM audit_system_write(
        CASE NEW.entity WHEN 'prices' THEN 'sync.prices.applied' ELSE 'sync.stock.applied' END,
        'sync_runs', NEW.id, NULL,
        jsonb_build_object(
          'syncRunId', NEW.id, 'entity', NEW.entity, 'mode', NEW.mode, 'changed', v_changed,
          'inserted', sync_run_count(NEW.counts, 'inserted'), 'updated', sync_run_count(NEW.counts, 'updated'),
          'markedDeleted', sync_run_count(NEW.counts, 'markedDeleted'),
          'syncedFrom', coalesce(NEW.started_at, NEW.created_at), 'syncedTo', coalesce(NEW.finished_at, now())),
        'ok', 'info');
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER trg_sync_runs_audit AFTER UPDATE OF status ON sync_runs
  FOR EACH ROW EXECUTE FUNCTION sync_runs_audit();

-- onec_outbox: → confirmed (`outbox.confirmed`), → failed (`outbox.rejected`, отказ 1С по данным), → dead
-- (`outbox.dead`, исчерпаны попытки / фатальная ошибка), → cancelled (`outbox.cancelled`). `outbox.retried` пишет
-- приложение (ручной повтор, sync-outbox.service.ts).
CREATE OR REPLACE FUNCTION onec_outbox_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_action text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NULL;
  END IF;
  v_action := CASE NEW.status
    WHEN 'confirmed' THEN 'outbox.confirmed'
    WHEN 'failed' THEN 'outbox.rejected'
    WHEN 'dead' THEN 'outbox.dead'
    WHEN 'cancelled' THEN 'outbox.cancelled'
  END;
  IF v_action IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM audit_system_write(
    v_action, 'onec_outbox', NEW.id, NEW.onec_ref,
    jsonb_build_object(
      'aggregateType', NEW.aggregate_type, 'aggregateId', NEW.aggregate_id, 'operation', NEW.operation,
      'statusBefore', OLD.status, 'status', NEW.status, 'attempts', NEW.attempts, 'errorCode', NEW.last_error_code),
    CASE WHEN NEW.status IN ('failed', 'dead') THEN 'error' ELSE 'ok' END,
    CASE WHEN NEW.status = 'dead' THEN 'critical' WHEN NEW.status = 'failed' THEN 'warning' ELSE 'info' END);
  RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER trg_onec_outbox_audit AFTER UPDATE OF status ON onec_outbox
  FOR EACH ROW EXECUTE FUNCTION onec_outbox_audit();

COMMIT;
