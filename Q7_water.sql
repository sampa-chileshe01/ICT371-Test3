-- Q7 Water Meter Readings and Billing (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a)
CREATE TABLE customers(customer_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE readings(
  reading_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id),
  reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT uq_cust_month UNIQUE (customer_id, reading_month));
CREATE TABLE bills(
  bill_id SERIAL PRIMARY KEY,
  reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on DATE NOT NULL,
  CONSTRAINT chk_paid CHECK (amount_paid >= 0 AND amount_paid <= charge));
CREATE TABLE receivable_snapshot(snapshot_date DATE PRIMARY KEY, total_due NUMERIC(14,2) NOT NULL);

INSERT INTO customers(full_name) VALUES ('Customer A'),('Customer B'),('Customer C');

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_check_reading() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;   -- rejected rows raise, so they are never stored
END; $$;
CREATE TRIGGER trg_readings_check BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_check_reading();

-- (b)
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN RAISE EXCEPTION 'Invalid consumption'; END IF;
  IF p_units <= 10 THEN RETURN ROUND(p_units * 5, 2);
  ELSE RETURN ROUND(50 + (p_units - 10) * 8, 2);
  END IF;
END; $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_cur NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date required'; END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_cur
    FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading %', p_reading_id; END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already billed', p_reading_id;
  END IF;
  INSERT INTO bills(reading_id,charge,amount_paid,due_on)
  VALUES (p_reading_id, fn_water_charge(v_cur - v_prev), 0, p_due_on);
END; $$;

-- seed: 0, exactly 10, and >10 units
INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading) VALUES
 (1,'2026-09-01',100,100),   -- 0 units
 (1,'2026-10-01',100,110),   -- 10 units
 (2,'2026-09-01',200,215),   -- 15 units
 (2,'2026-10-01',215,240),   -- 25 units
 (3,'2026-09-01',50,55),     -- 5 units
 (3,'2026-10-01',55,75);     -- 20 units
CALL pr_generate_bill(1,CURRENT_DATE-40);
CALL pr_generate_bill(2,CURRENT_DATE-10);
CALL pr_generate_bill(3,CURRENT_DATE-20);
CALL pr_generate_bill(4,CURRENT_DATE+10);
CALL pr_generate_bill(5,CURRENT_DATE-5);
CALL pr_generate_bill(6,CURRENT_DATE+15);
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;         -- fully paid
UPDATE bills SET amount_paid = 20 WHERE reading_id = 3;             -- partly paid

-- (e)
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills;

-- (f) partial index: only unpaid bills, ordered by due date
CREATE INDEX idx_bills_unpaid_due ON bills(due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_receivables() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot(snapshot_date,total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid),0) FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END; $$;
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
SELECT cron.schedule('refresh_receivables','30 0 * * *',$$CALL pr_refresh_receivables()$$);
