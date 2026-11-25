-- Q5 Hostel Room Allocation (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a)
CREATE TABLE students(
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL);
CREATE TABLE rooms(
  room_id SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity INT NOT NULL CHECK (capacity > 0));
CREATE TABLE allocations(
  allocation_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  room_id INT NOT NULL REFERENCES rooms(room_id),
  allocated_on DATE NOT NULL,
  released_on DATE,
  status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  CONSTRAINT chk_status_release CHECK (
    (status='ACTIVE' AND released_on IS NULL) OR
    (status='ENDED'  AND released_on IS NOT NULL)));
CREATE TABLE occupancy_snapshot(
  snapshot_date DATE NOT NULL,
  room_id INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL, free_beds INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id));

INSERT INTO students(student_number,full_name) VALUES
 ('H001','Student A'),('H002','Student B'),('H003','Student C'),('H004','Student D'),('H005','Student E');
INSERT INTO rooms(room_number,capacity) VALUES ('101',2),('102',3),('103',2);

-- (b)
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;
  SELECT COUNT(*) INTO v_used FROM allocations WHERE room_id = p_room_id AND status='ACTIVE';
  RETURN v_cap - v_used;
END; $$;

-- (d) Trigger (also protects direct SQL)
CREATE OR REPLACE FUNCTION trg_alloc_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE; -- lock room
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status='ACTIVE'
                 AND allocation_id <> NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_used FROM allocations
     WHERE room_id = NEW.room_id AND status='ACTIVE' AND allocation_id <> NEW.allocation_id;
    IF v_used >= v_cap THEN RAISE EXCEPTION 'Room % is full', NEW.room_id; END IF;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_alloc BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_rules();

-- (c)
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;
  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date required'; END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status='ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN RAISE EXCEPTION 'Room % has no free beds', p_room_id; END IF;
  INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status)
  VALUES (p_student_id,p_room_id,p_allocated_on,NULL,'ACTIVE');
END; $$;

-- seed: 101 full, 102 partly, 103 empty, plus history
CALL pr_allocate_room(1,1,CURRENT_DATE-30);
CALL pr_allocate_room(2,1,CURRENT_DATE-20);
CALL pr_allocate_room(3,2,CURRENT_DATE-10);
INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status)
VALUES (4,3,CURRENT_DATE-90,CURRENT_DATE-60,'ENDED');

-- (e)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status='ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy;

-- (f) partial index on ACTIVE rows only
CREATE INDEX idx_alloc_active_room ON allocations(room_id) WHERE status='ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date,room_id,occupied_beds,free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
  ON CONFLICT (snapshot_date,room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END; $$;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;
SELECT cron.schedule('refresh_occupancy','55 23 * * *',$$CALL pr_refresh_occupancy()$$);
