-- Q2 University Fee Payments (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a)
CREATE TABLE students(
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0));
CREATE TABLE payments(
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on DATE NOT NULL DEFAULT CURRENT_DATE);
CREATE TABLE payment_audit(
  audit_id SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(12,2) NOT NULL,
  logged_at TIMESTAMP NOT NULL DEFAULT now());
CREATE TABLE daily_collections(
  collection_date DATE PRIMARY KEY,
  payment_count INT NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL);

INSERT INTO students(student_number,full_name,fee_due) VALUES
 ('S001','Mwansa Banda',5000),('S002','Chanda Phiri',3000),('S003','Natasha Zulu',2000);

-- (b)
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC; v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
  SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;
END; $$;

-- (c) audit is NOT inserted here; the trigger does it
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_bal NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise per student
  v_bal := fn_fee_balance(p_student_id);  -- raises if unknown student
  IF p_amount > v_bal THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_bal;
  END IF;
  INSERT INTO payments(student_id,amount,paid_on)
  VALUES (p_student_id,p_amount,COALESCE(p_paid_on,CURRENT_DATE));
END; $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit(payment_id,student_id,amount,logged_at)
  VALUES (NEW.payment_id,NEW.student_id,NEW.amount,now());
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_payments_audit AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- seed payments (S003 has none)
CALL pr_receive_payment(1,1000,CURRENT_DATE-3);
CALL pr_receive_payment(1,1500,CURRENT_DATE-2);
CALL pr_receive_payment(1,500, CURRENT_DATE-1);
CALL pr_receive_payment(2,1000,CURRENT_DATE-2);
CALL pr_receive_payment(2,1000,CURRENT_DATE-1);
CALL pr_receive_payment(2,1000,CURRENT_DATE-1);   -- S002 fully settled

-- (e)
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM students s LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount),0) > 0;
SELECT * FROM v_fee_balances;

-- (f) equality column first, range column second
CREATE INDEX idx_payments_student_paid ON payments(student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections(collection_date,payment_count,total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount),0) FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END; $$;
CALL pr_refresh_collections(CURRENT_DATE-1);
CALL pr_refresh_collections(CURRENT_DATE-1);
SELECT * FROM daily_collections;
SELECT cron.schedule('refresh_collections','0 1 * * *',$$CALL pr_refresh_collections(CURRENT_DATE-1)$$);
