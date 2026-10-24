-- pos-api/db/migrations-dev/0001_dev_outbox.sql — dev/test-таблица dev_outbox (07 §5.63, DATA-169; ядро §17.3).
-- RM-C-006 п. 6 (ревью B-AR-09, C-MJ-05): DDL перенесён из migrations/0001_init.sql. Каталог db/migrations-dev/
-- применяется мигратором (src/migrate.ts) только при APP_ENV=dev, журнал — pos_dev.schema_migrations; раннер
-- tools/pg — вторым файлом после 0001/0002 с --set app.env=test. В prod-образ pos-api каталог не копируется
-- (Dockerfile копирует только migrations/ и seeds/), поэтому grep 'CREATE TABLE.*dev_outbox' по миграциям
-- prod-образа даёт 0 совпадений (AC-DATA-169). FakeSmsGateway пишет сюда текст SMS (RM-C-008); ретенция 24 ч.
-- Отказ закрыт: в сеансе, не помеченном как dev/test (app.env), файл завершается ошибкой и ничего не создаёт.
BEGIN;

DO $$
BEGIN
  IF coalesce(current_setting('app.env', true), '') NOT IN ('dev', 'test') THEN
    RAISE EXCEPTION 'dev_outbox: только dev/test-схема (app.env=%)', coalesce(current_setting('app.env', true), '<не задан>');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS dev_outbox (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  transaction_id      text NOT NULL CONSTRAINT dev_outbox_transaction_id_chk CHECK (transaction_id ~ '^[A-Za-z0-9]{12}$'),
  sms_outbox_id       uuid CONSTRAINT dev_outbox_sms_outbox_id_fk REFERENCES sms_outbox(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  phone_e164          text NOT NULL CONSTRAINT dev_outbox_phone_e164_chk CHECK (phone_e164 ~ '^\+996[0-9]{9}$'),
  template_key        text NOT NULL CONSTRAINT dev_outbox_template_key_chk CHECK (template_key IN ('otp_login','otp_step_up','otp_phone_change','otp_customer_link')),
  text                text NOT NULL,
  simulated_status_code smallint,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS dev_outbox_transaction_id_uq ON dev_outbox (transaction_id);
CREATE INDEX IF NOT EXISTS dev_outbox_phone_created_idx ON dev_outbox (phone_e164, created_at DESC);
CREATE INDEX IF NOT EXISTS dev_outbox_created_idx ON dev_outbox (created_at);
CREATE INDEX IF NOT EXISTS dev_outbox_sms_outbox_idx ON dev_outbox (sms_outbox_id);

-- То, что 0001_init.sql делает для всех таблиц public (§10.1 updated_at, §11 права ролей), — для этой таблицы явно:
-- схема dev/test остаётся той же, что до переноса (docs/erd/schema_v1.sql).
CREATE OR REPLACE TRIGGER trg_dev_outbox_set_updated_at BEFORE UPDATE ON dev_outbox
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
GRANT SELECT, INSERT, UPDATE, DELETE ON dev_outbox TO pos_app;
GRANT SELECT ON dev_outbox TO pos_readonly, pos_backup;

COMMIT;
