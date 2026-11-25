-- Q4 Clinic Appointment Scheduling (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a)
CREATE TABLE patients(patient_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors(doctor_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE appointments(
  appointment_id SERIAL PRIMARY KEY,
  patient_id INT NOT NULL REFERENCES patients(patient_id),
  doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  status VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
         CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')));
CREATE TABLE clinic_summary(
  summary_date DATE PRIMARY KEY,
  booked_count INT NOT NULL, attended_count INT NOT NULL, cancelled_count INT NOT NULL);

INSERT INTO patients(full_name) VALUES ('Patient One'),('Patient Two'),('Patient Three');
INSERT INTO doctors(full_name) VALUES ('Dr Mulenga'),('Dr Tembo'),('Dr Mumba');

-- (d) Trigger first so seed data is protected too
CREATE OR REPLACE FUNCTION trg_check_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
       SELECT 1 FROM appointments a
       WHERE a.doctor_id = NEW.doctor_id
         AND a.appointment_day = NEW.appointment_day
         AND a.slot_time = NEW.slot_time
         AND a.status <> 'CANCELLED'
         AND a.appointment_id <> NEW.appointment_id) THEN  -- excludes row being updated
    RAISE EXCEPTION 'Doctor % already booked on % at %',
      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_appt_clash BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_check_clash();

-- (b)
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_n INT;
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;
  SELECT COUNT(*) INTO v_n FROM appointments
   WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
  RETURN v_n;   -- COUNT gives 0 when no rows
END; $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient %', p_patient_id; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN RAISE EXCEPTION 'Date cannot be in the past'; END IF;
  IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE EXCEPTION 'Unsupported slot %', p_slot;
  END IF;
  INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status)
  VALUES (p_patient_id,p_doctor_id,p_day,p_slot,'BOOKED');
END; $$;

-- seed: 6 appointments, no slot clash
CALL pr_book_appointment(1,1,CURRENT_DATE,'09:00');
CALL pr_book_appointment(2,1,CURRENT_DATE,'10:00');
CALL pr_book_appointment(3,2,CURRENT_DATE,'09:00');
CALL pr_book_appointment(1,3,CURRENT_DATE+1,'11:00');
INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status) VALUES
 (2,2,CURRENT_DATE-1,'09:00','ATTENDED'),
 (3,3,CURRENT_DATE-1,'10:00','CANCELLED');

-- (e)
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments;

-- (f)
CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date,booked_count,attended_count,cancelled_count)
  SELECT p_day,
    COUNT(*) FILTER (WHERE status='BOOKED'),
    COUNT(*) FILTER (WHERE status='ATTENDED'),
    COUNT(*) FILTER (WHERE status='CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE SET
    booked_count = EXCLUDED.booked_count,
    attended_count = EXCLUDED.attended_count,
    cancelled_count = EXCLUDED.cancelled_count;
END; $$;
CALL pr_refresh_clinic_summary(CURRENT_DATE-1);
CALL pr_refresh_clinic_summary(CURRENT_DATE-1);
SELECT * FROM clinic_summary;
SELECT cron.schedule('refresh_clinic','0 1 * * *',$$CALL pr_refresh_clinic_summary(CURRENT_DATE-1)$$);
