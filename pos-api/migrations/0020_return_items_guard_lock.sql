-- 0020_return_items_guard_lock.sql — сериализация строк заявок на возврат в триггере (known_issues G-KI-14; остаток
-- ревью G-returns-txn-5).
--
-- Триггер `return_request_items_guard` (0001, 07 §5.46; 10 RET-003, RET-008) проверяет «quantity ≤ отгружено −
-- возвращено − другие открытые заявки», но читал строку реализации `shipment_items` без блокировки: две параллельные
-- вставки на одну строку реализации в обход сервиса (прямой SQL, второй процесс) видели снимок без строк друг друга и
-- обе проходили. Сервис `returns` сериализует заявки `SELECT … FOR UPDATE OF si` (ReturnsRepository.shipmentLines),
-- а триггер — последняя защита — этого не делал.
--
-- Исправление: строка `shipment_items` читается `FOR NO KEY UPDATE` — вторая вставка/изменение строки заявки на ту же
-- строку реализации ждёт COMMIT/ROLLBACK первой, а сумма «других открытых заявок» читается следующим оператором уже
-- после получения блокировки (READ COMMITTED — новый снимок на оператор) и видит зафиксированные строки первой.
-- `NO KEY UPDATE` конфликтует сам с собой и с `FOR UPDATE` сервиса, но не с `FOR KEY SHARE` проверки внешнего ключа
-- `return_request_items_shipment_item_id_fk`. Правила (статус `draft`, остаток, `line_total`) и тексты ошибок —
-- прежние: бизнес-правила не меняются.
--
-- Expand-only (07 §13), идемпотентно (CREATE OR REPLACE): повторное применение — 0 изменений.

BEGIN;

CREATE OR REPLACE FUNCTION return_request_items_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status return_request_status; si record; v_other numeric;
BEGIN
  SELECT status INTO v_status FROM return_requests
   WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.return_request_id ELSE NEW.return_request_id END;
  IF FOUND AND v_status <> 'draft' AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'return_request_items: lines are immutable after submit (return request is %)', v_status
      USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  -- Сериализация по строке реализации (G-KI-14): блокировка до подсчёта других открытых заявок.
  SELECT quantity, returned_quantity, line_total INTO si FROM shipment_items WHERE id = NEW.shipment_item_id
    FOR NO KEY UPDATE;
  SELECT coalesce(sum(i.quantity), 0) INTO v_other
    FROM return_request_items i JOIN return_requests r ON r.id = i.return_request_id
   WHERE i.shipment_item_id = NEW.shipment_item_id AND i.return_request_id <> NEW.return_request_id
     AND r.status IN ('draft','submitted','accepted');
  IF NEW.quantity > si.quantity - si.returned_quantity - v_other THEN
    RAISE EXCEPTION 'return_request_items: quantity % exceeds returnable % (shipment item %)',
      NEW.quantity, si.quantity - si.returned_quantity - v_other, NEW.shipment_item_id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.line_total IS DISTINCT FROM round_half_up(si.line_total * NEW.quantity / si.quantity, 2) THEN
    RAISE EXCEPTION 'return_request_items: line_total % <> round_half_up(shipment line_total × quantity / shipped quantity, 2) = %',
      NEW.line_total, round_half_up(si.line_total * NEW.quantity / si.quantity, 2) USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

COMMIT;
