-- Самопроверка раннера: таблица, данные, функция с $$ и ; внутри, E-строка, комментарии.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS selftest_items (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name    text NOT NULL,          -- комментарий; с точкой с запятой
  price   numeric(14,2) NOT NULL CHECK (price >= 0)
);
/* блочный комментарий; /* вложенный; */ конец */
INSERT INTO selftest_items (name, price)
SELECT v.name, v.price FROM (VALUES ('Смеситель для кухни', 4500.00), (E'Труба PPR 20 \'хол.\'; d=20', 120.50)) AS v(name, price)
WHERE NOT EXISTS (SELECT 1 FROM selftest_items);

CREATE OR REPLACE FUNCTION selftest_total() RETURNS numeric LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN (SELECT sum(price) FROM selftest_items); -- ; внутри тела
END;
$fn$;

CREATE OR REPLACE FUNCTION selftest_double(x numeric) RETURNS numeric LANGUAGE sql
BEGIN ATOMIC
  SELECT CASE WHEN x IS NULL THEN 0 ELSE x * 2 END;
END;

SELECT version();
