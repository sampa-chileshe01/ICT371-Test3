-- Q9 Farmer Cooperative Maize Deliveries (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a)
CREATE TABLE farmers(
  farmer_id SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL);
CREATE TABLE deliveries(
  delivery_id SERIAL PRIMARY KEY,
  farmer_id INT NOT NULL REFERENCES farmers(farmer_id),
  grade CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate NUMERIC(10,2) NOT NULL,      -- set by trigger
  total_value NUMERIC(12,2) NOT NULL,    -- set by trigger
  delivered_on DATE NOT NULL,
  is_paid BOOLEAN NOT NULL DEFAULT FALSE);
CREATE TABLE daily_purchases(
  purchase_date DATE PRIMARY KEY,
  total_weight NUMERIC(12,2) NOT NULL,
  total_value NUMERIC(14,2) NOT NULL);

INSERT INTO farmers(farmer_number,full_name) VALUES
 ('F001','Farmer One'),('F002','Farmer Two'),('F003','Farmer Three');

-- (b)
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_rate NUMERIC;
BEGIN
  IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade required'; END IF;
  v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;
  IF v_rate IS NULL THEN RAISE EXCEPTION 'Unsupported grade %', p_grade; END IF;
  RETURN v_rate;
END; $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_delivery_price() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_deliveries_price BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_price();

-- (c) rate/total are NOT supplied: trigger fills them (placeholders 0 satisfy NOT NULL pre-trigger)
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer %', p_farmer_id; END IF;
  IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN RAISE EXCEPTION 'Invalid grade %', p_grade; END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN RAISE EXCEPTION 'Weight must be positive'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Date required'; END IF;
  INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on,is_paid)
  VALUES (p_farmer_id,p_grade,p_weight,0,0,p_date,FALSE);
END; $$;

-- seed: all grades, both payment states
CALL pr_receive_delivery(1,'A',100,CURRENT_DATE-2);
CALL pr_receive_delivery(1,'B',200,CURRENT_DATE-1);
CALL pr_receive_delivery(2,'C',150,CURRENT_DATE-1);
CALL pr_receive_delivery(2,'A',80, CURRENT_DATE-1);
CALL pr_receive_delivery(3,'B',120,CURRENT_DATE-3);
-- direct SQL follows the same pricing rule
INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on,is_paid)
VALUES (3,'C',60,0,0,CURRENT_DATE-1,FALSE);
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1,5);

-- (e)
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE),0) AS amount_due
FROM farmers f LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;
SELECT * FROM v_farmer_amount_due;

-- (f)
CREATE INDEX idx_deliv_farmer_date ON deliveries(farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases(purchase_date,total_weight,total_value)
  SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END; $$;
CALL pr_refresh_purchases(CURRENT_DATE-1);
CALL pr_refresh_purchases(CURRENT_DATE-1);
SELECT * FROM daily_purchases;
SELECT cron.schedule('refresh_purchases','30 1 * * *',$$CALL pr_refresh_purchases(CURRENT_DATE-1)$$);
