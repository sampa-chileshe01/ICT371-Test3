-- Q6 Monthly Payroll Processing (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a)
CREATE TABLE employees(
  employee_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE payroll(
  payroll_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay NUMERIC(12,2) NOT NULL,
  net_pay NUMERIC(12,2) NOT NULL,
  CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month));
CREATE TABLE salary_audit(
  audit_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary NUMERIC(12,2), new_salary NUMERIC(12,2),
  changed_at TIMESTAMP NOT NULL DEFAULT now());

INSERT INTO employees(full_name,basic_salary,allowance,deduction,active) VALUES
 ('Grace Mwale',5000,500,600,TRUE),
 ('Peter Sakala',4000,300,400,TRUE),
 ('Joyce Kunda',3500,200,350,TRUE);

-- (b)
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee %', p_employee_id; END IF;
  IF v_net < 0 THEN RAISE EXCEPTION 'Negative net pay for employee %', p_employee_id; END IF;
  RETURN v_net;
END; $$;

-- (c) any exception aborts the whole CALL (single transaction)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE) LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month';
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance FROM employees
           WHERE active ORDER BY employee_id LOOP
    v_net := fn_net_pay(r.employee_id);   -- raises on invalid calculation
    INSERT INTO payroll(employee_id,pay_month,gross_pay,net_pay)
    VALUES (r.employee_id,p_month,r.basic_salary + r.allowance,v_net)
    ON CONFLICT (employee_id,pay_month) DO NOTHING;  -- existing rows unchanged
  END LOOP;
END; $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit(employee_id,old_salary,new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_emp_salary AFTER UPDATE ON employees
FOR EACH ROW WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- seed two months; Joyce becomes inactive after the first month
CALL pr_process_payroll(DATE '2026-09-01');
UPDATE employees SET active = FALSE WHERE employee_id = 3;
UPDATE employees SET basic_salary = 5200 WHERE employee_id = 1;  -- audited
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-10-01');  -- rerun: nothing changes

-- (e) INNER JOIN so inactive employees' history stays
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) UNIQUE(employee_id,pay_month) can't serve pay_month-only filters (employee_id is leading);
-- this index leads with pay_month and INCLUDEs the report columns.
CREATE INDEX idx_payroll_month ON payroll(pay_month) INCLUDE (gross_pay, net_pay);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) 02:00 on day 1 of each month, previous month's first date
SELECT cron.schedule('monthly_payroll','0 2 1 * *',
 $$CALL pr_process_payroll((date_trunc('month',CURRENT_DATE) - INTERVAL '1 month')::date)$$);
-- Inspect job and history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
