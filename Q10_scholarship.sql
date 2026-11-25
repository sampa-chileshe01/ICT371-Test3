-- Q10 Scholarship Application Assessment (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a)
CREATE TABLE students(
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL);
CREATE TABLE applications(
  application_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
  status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
         CHECK (status IN ('PENDING','APPROVED','REJECTED')));
CREATE TABLE decision_audit(
  audit_id SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status VARCHAR(10), new_status VARCHAR(10),
  changed_at TIMESTAMP NOT NULL DEFAULT now());

INSERT INTO students(student_number,full_name) VALUES
 ('SC001','Student One'),('SC002','Student Two'),('SC003','Student Three');

-- seed: qualifying, non-qualifying and boundary cases
INSERT INTO applications(student_id,age_at_application,monthly_income,average_mark,submitted_on,status) VALUES
 (1,20,1500,80,CURRENT_DATE-6,'PENDING'),   -- qualifies
 (1,18,3000,70,CURRENT_DATE-5,'PENDING'),   -- lower boundaries: qualifies
 (2,25,3000,70,CURRENT_DATE-4,'PENDING'),   -- upper age boundary: qualifies
 (2,26,1000,90,CURRENT_DATE-3,'PENDING'),   -- too old
 (3,22,3001,85,CURRENT_DATE-2,'PENDING'),   -- income just over
 (3,17,500,95,CURRENT_DATE-1,'PENDING');    -- too young

-- (b)
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN RAISE EXCEPTION 'Inputs cannot be NULL'; END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END; $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit(application_id,old_status,new_status,changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_app_status AFTER UPDATE ON applications
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (c)
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT) LANGUAGE plpgsql AS $$
DECLARE a applications%ROWTYPE;
BEGIN
  SELECT * INTO a FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application %', p_application_id; END IF;
  IF a.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % already assessed (%)', p_application_id, a.status;
  END IF;
  UPDATE applications
     SET status = CASE WHEN fn_scholarship_eligible(a.age_at_application,a.monthly_income,a.average_mark)
                       THEN 'APPROVED' ELSE 'REJECTED' END
   WHERE application_id = p_application_id;
END; $$;

-- (e)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) equality column first, range column second
CREATE INDEX idx_app_status_submitted ON applications(status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE-30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) only PENDING rows are selected, so reruns do nothing and add no audit rows
CREATE OR REPLACE PROCEDURE pr_assess_pending() LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END; $$;
CALL pr_assess_pending();
CALL pr_assess_pending();   -- rerun: nothing reassessed
SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit;
SELECT * FROM v_approved_applicants;
SELECT cron.schedule('assess_pending','0 8 * * 1',$$CALL pr_assess_pending()$$);
