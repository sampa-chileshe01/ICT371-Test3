-- Q8 Transport Fleet Maintenance (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a)
CREATE TABLE vehicles(
  vehicle_id SERIAL PRIMARY KEY,
  registration VARCHAR(15) NOT NULL UNIQUE,
  current_odometer INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer));
CREATE TABLE trips(
  trip_id SERIAL PRIMARY KEY,
  vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer INT NOT NULL CHECK (end_odometer >= 0));
CREATE TABLE service_alerts(
  vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on DATE NOT NULL DEFAULT CURRENT_DATE);

INSERT INTO vehicles(registration,current_odometer,last_service_odometer) VALUES
 ('ABC 1001',10000,4000),   -- 6000 km: due
 ('ABC 1002',20000,17000),  -- 3000 km: not due
 ('ABC 1003',30000,26000);  -- 4000 km: not due yet, becomes due after trips

-- (d) Trigger: verify, then update odometer exactly once
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
  SELECT current_odometer INTO v_cur FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id; END IF;
  IF NEW.start_odometer <> v_cur THEN
    RAISE EXCEPTION 'Start odometer % does not match current value %', NEW.start_odometer, v_cur;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'End odometer must be greater than start odometer';
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_trips_before_ins BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (b)
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE v_cur INT; v_last INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
  RETURN (v_cur - v_last) >= 5000;
END; $$;

-- (c) does NOT touch vehicles; trigger does that
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
  END IF;
  INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer)
  VALUES (p_vehicle_id,COALESCE(p_trip_on,CURRENT_DATE),p_start,p_end);
END; $$;

-- seed 6 trips through the procedure (after trigger exists)
CALL pr_record_trip(1,CURRENT_DATE-6,10000,10200);
CALL pr_record_trip(1,CURRENT_DATE-3,10200,10500);
CALL pr_record_trip(2,CURRENT_DATE-5,20000,20300);
CALL pr_record_trip(2,CURRENT_DATE-2,20300,20700);
CALL pr_record_trip(3,CURRENT_DATE-4,30000,30600);
CALL pr_record_trip(3,CURRENT_DATE-1,30600,31000);   -- 31000-26000 = 5000: due

-- (e)
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f) equality on vehicle_id, range on trip_on
CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE-30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts(vehicle_id,km_since_service,flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;
  DELETE FROM service_alerts WHERE vehicle_id NOT IN
    (SELECT vehicle_id FROM vehicles WHERE current_odometer - last_service_odometer >= 5000);
END; $$;
CALL pr_refresh_service_alerts();
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1; -- serviced
CALL pr_refresh_service_alerts();   -- alert for vehicle 1 removed
SELECT * FROM service_alerts;
SELECT cron.schedule('refresh_service_alerts','0 6 * * 1',$$CALL pr_refresh_service_alerts()$$);
