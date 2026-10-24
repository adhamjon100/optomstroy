SELECT version();
SELECT current_setting('server_version') AS server_version, current_database() AS db;
SELECT id, name, price FROM selftest_items ORDER BY id;
SELECT selftest_total() AS total, selftest_double(21) AS doubled;
SELECT lower('СМЕСИТЕЛЬ') AS lower_ru, unaccent('Ёлка café') AS unaccent, show_trgm('Смеситель') AS trgm,
       similarity('смеситель', 'Смеситель для кухни') > 0.3 AS trgm_match,
       length(gen_random_uuid()::text) AS uuid_len;
DO $$ BEGIN
  IF (SELECT count(*) FROM selftest_items) <> 2 THEN RAISE EXCEPTION 'ожидалось 2 строки'; END IF;
END $$;
