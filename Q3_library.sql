-- Q3 Library Returns and Overdue Fines (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a)
CREATE TABLE books(book_id SERIAL PRIMARY KEY, title VARCHAR(150) NOT NULL);
CREATE TABLE loans(
  loan_id SERIAL PRIMARY KEY,
  book_id INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on DATE NOT NULL,
  due_on DATE NOT NULL,
  returned_on DATE,
  fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT chk_due CHECK (due_on >= borrowed_on));
CREATE TABLE loan_audit(
  audit_id SERIAL PRIMARY KEY,
  loan_id INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on DATE, new_returned_on DATE,
  changed_at TIMESTAMP NOT NULL DEFAULT now());
CREATE TABLE overdue_summary(
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine NUMERIC(12,2) NOT NULL);

INSERT INTO books(title) VALUES ('Database Systems'),('Clean Code'),('Networks');

-- (b)
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;
  v_end := CASE WHEN v_ret IS NOT NULL THEN LEAST(p_as_of, v_ret) ELSE p_as_of END;
  RETURN 2 * GREATEST(v_end - v_due, 0);
END; $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE;
BEGIN
  IF p_returned_on IS NULL THEN RAISE EXCEPTION 'Return date required'; END IF;
  SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;
  IF v_ret IS NOT NULL THEN RAISE EXCEPTION 'Loan % already returned', p_loan_id; END IF;
  IF p_returned_on < v_borrowed THEN RAISE EXCEPTION 'Return before borrow date'; END IF;
  UPDATE loans
     SET returned_on = p_returned_on,
         fine_amount = fn_loan_fine(p_loan_id, p_returned_on)  -- as_of = return date
   WHERE loan_id = p_loan_id;
END; $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit(loan_id,old_returned_on,new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_loans_audit AFTER UPDATE ON loans
FOR EACH ROW WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

-- seed
INSERT INTO loans(book_id,borrower_name,borrowed_on,due_on) VALUES
 (1,'Alice',CURRENT_DATE-30,CURRENT_DATE-16),  -- open overdue
 (2,'Bob',  CURRENT_DATE-5, CURRENT_DATE+9),   -- on time, open
 (3,'Carol',CURRENT_DATE-40,CURRENT_DATE-26),  -- returned late
 (1,'Dan',  CURRENT_DATE-20,CURRENT_DATE-6),   -- open overdue
 (2,'Eve',  CURRENT_DATE-25,CURRENT_DATE-11),  -- returned on due date
 (3,'Frank',CURRENT_DATE-3, CURRENT_DATE+11);  -- open on time
CALL pr_return_loan(3,CURRENT_DATE-20);
CALL pr_return_loan(5,CURRENT_DATE-11);

-- (e)
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) partial index: only unreturned loans, small and fast
CREATE INDEX idx_loans_book_open ON loans(book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary(snapshot_date,overdue_count,total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id,p_as_of)),0)
  FROM loans
  WHERE (returned_on IS NULL OR returned_on > p_as_of) AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END; $$;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;
SELECT cron.schedule('refresh_overdue','10 0 * * *',$$CALL pr_refresh_overdue(CURRENT_DATE)$$);
