/* =====================================================================
   03_views.sql  -  BPS_ServiceDB

   Views (7):
     vw_hall_availability     customers: upcoming booked slots per hall
     vw_daily_bookings        staff: every reservation by day
     vw_current_rentals       staff: items out right now
     vw_overdue_items         staff: items out past their due date
     vw_item_stock            customers/staff: stock and items out now
     vw_requests_over_target  staff: open requests past their target time
     vw_service_performance   management: time taken against target

   Time note: reservation times are local (SYSDATETIME, server clock should be
   Sri Lanka time). Request dates are UTC (SYSUTCDATETIME).
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- 1. Hall availability (safe for customers: no personal data) ----------
   One row per upcoming Approved/Confirmed booking. A hall with no upcoming
   booking appears once with NULL booked_from / booked_to. Free time = gaps. */
CREATE OR ALTER VIEW dbo.vw_hall_availability
AS
SELECT h.hall_id,
       h.name           AS hall_name,
       h.capacity,
       h.rental_charge,
       h.charge_basis,
       hr.start_datetime AS booked_from,
       hr.end_datetime   AS booked_to
FROM Hall h
LEFT JOIN Hall_Reservation hr
       ON hr.hall_id = h.hall_id
      AND hr.status IN ('Approved','Confirmed')
      AND hr.end_datetime >= SYSDATETIME()
WHERE h.is_active = 1;
GO

/* ---------- 2. Daily bookings (staff) ----------
   Filter in the query: WHERE booking_date = '2026-12-20' */
CREATE OR ALTER VIEW dbo.vw_daily_bookings
AS
SELECT CAST(hr.start_datetime AS DATE) AS booking_date,
       hr.start_datetime,
       hr.end_datetime,
       hr.request_id          AS reservation_id,
       h.hall_id,
       h.name                 AS hall_name,
       c.customer_id,
       c.full_name            AS customer_name,
       c.contact_no,
       hr.purpose,
       hr.expected_crowd,
       hr.status
FROM Hall_Reservation hr
JOIN Hall h             ON h.hall_id = hr.hall_id
JOIN Service_Request sr ON sr.request_id = hr.request_id
JOIN Customer c         ON c.customer_id = sr.customer_id;
GO

/* ---------- 3. Current rentals (staff): lines still out ----------
   outstanding = issued - returned - damaged/lost (damaged units are not coming back) */
CREATE OR ALTER VIEW dbo.vw_current_rentals
AS
SELECT ir.request_id AS rental_id,
       c.customer_id,
       c.full_name   AS customer_name,
       c.contact_no,
       i.item_id,
       i.name        AS item_name,
       rl.quantity_issued,
       rl.quantity_returned,
       ISNULL(d.damaged_qty, 0) AS quantity_damaged,
       rl.quantity_issued - rl.quantity_returned - ISNULL(d.damaged_qty, 0) AS quantity_outstanding,
       ir.issue_date,
       ir.due_date
FROM Item_Rental ir
JOIN Service_Request sr ON sr.request_id = ir.request_id
JOIN Customer c         ON c.customer_id = sr.customer_id
JOIN Rental_Line rl     ON rl.rental_id = ir.request_id
JOIN Item i             ON i.item_id = rl.item_id
OUTER APPLY (SELECT SUM(dr.quantity) AS damaged_qty
             FROM Damage_Record dr
             WHERE dr.rental_id = rl.rental_id AND dr.item_id = rl.item_id) d
WHERE ir.status = 'Issued'
  AND rl.quantity_issued - rl.quantity_returned - ISNULL(d.damaged_qty, 0) > 0;
GO

/* ---------- 4. Overdue items (staff) ----------
   'Overdue' is derived here, not stored in a table. */
CREATE OR ALTER VIEW dbo.vw_overdue_items
AS
SELECT rental_id,
       customer_id,
       customer_name,
       contact_no,
       item_id,
       item_name,
       quantity_outstanding,
       issue_date,
       due_date,
       DATEDIFF(DAY, due_date, CAST(SYSDATETIME() AS DATE)) AS days_overdue
FROM dbo.vw_current_rentals
WHERE due_date < CAST(SYSDATETIME() AS DATE);
GO

/* ---------- 5. Item stock ----------
   available_now = items physically in the store (total - out now).
   For a future date range use dbo.fn_item_available (04_procedures.sql). */
CREATE OR ALTER VIEW dbo.vw_item_stock
AS
SELECT i.item_id,
       i.name AS item_name,
       i.category,
       i.total_quantity,
       ISNULL(SUM(cr.quantity_outstanding), 0) AS quantity_out_now,
       CASE WHEN i.total_quantity - ISNULL(SUM(cr.quantity_outstanding), 0) < 0
            THEN 0
            ELSE i.total_quantity - ISNULL(SUM(cr.quantity_outstanding), 0) END AS available_now,
       i.rental_charge,
       i.charge_basis
FROM Item i
LEFT JOIN dbo.vw_current_rentals cr ON cr.item_id = i.item_id
WHERE i.is_active = 1
GROUP BY i.item_id, i.name, i.category, i.total_quantity, i.rental_charge, i.charge_basis;
GO

/* ---------- 6. Requests over target time (staff) ----------
   Open = still waiting for processing. A rental in use (BPS/8 InProgress)
   is not "late", so it is excluded; it appears in vw_overdue_items instead. */
CREATE OR ALTER VIEW dbo.vw_requests_over_target
AS
SELECT sr.request_id,
       sr.service_code,
       sc.service_name,
       c.full_name      AS customer_name,
       sr.submitted_date,
       sr.due_date,
       sr.status,
       u.username       AS assigned_officer,
       DATEDIFF(DAY, sr.due_date, SYSUTCDATETIME()) AS days_over_target
FROM Service_Request sr
JOIN Service_Catalog sc ON sc.service_code = sr.service_code
JOIN Customer c         ON c.customer_id = sr.customer_id
LEFT JOIN User_Account u ON u.user_id = sr.assigned_officer_id
WHERE sr.due_date IS NOT NULL
  AND sr.due_date < SYSUTCDATETIME()
  AND (sr.status = 'Pending'
       OR (sr.status = 'InProgress' AND sr.service_code <> 'BPS/8'));
GO

/* ---------- 7. Service performance (management) ----------
   Time taken = submitted date to the last officer decision (Request_Approval).
   Services without officer decisions (halls, rentals) show NULL for time and
   on-time %, but still show request counts. */
CREATE OR ALTER VIEW dbo.vw_service_performance
AS
WITH decided AS (
    SELECT sr.request_id, sr.submitted_date, MAX(ra.decided_at) AS closed_at
    FROM Service_Request sr
    JOIN Request_Approval ra ON ra.request_id = sr.request_id
    WHERE sr.status IN ('Approved','Rejected','Completed')
    GROUP BY sr.request_id, sr.submitted_date
)
SELECT sc.service_code,
       sc.service_name,
       sc.target_days,
       COUNT(sr.request_id) AS total_requests,
       SUM(CASE WHEN sr.status IN ('Pending','InProgress') THEN 1 ELSE 0 END)            AS open_requests,
       SUM(CASE WHEN sr.status IN ('Approved','Rejected','Completed') THEN 1 ELSE 0 END) AS decided_requests,
       SUM(CASE WHEN sr.status = 'Cancelled' THEN 1 ELSE 0 END)                          AS cancelled_requests,
       CAST(AVG(CASE WHEN d.closed_at IS NOT NULL
                     THEN DATEDIFF(HOUR, d.submitted_date, d.closed_at) / 24.0 END) AS DECIMAL(10,1)) AS avg_days_to_decide,
       SUM(CASE WHEN d.closed_at IS NOT NULL
                 AND d.closed_at <= DATEADD(DAY, sc.target_days, d.submitted_date) THEN 1 ELSE 0 END) AS decided_on_time,
       CASE WHEN COUNT(d.closed_at) = 0 THEN NULL
            ELSE CAST(100.0 * SUM(CASE WHEN d.closed_at <= DATEADD(DAY, sc.target_days, d.submitted_date)
                                       THEN 1 ELSE 0 END) / COUNT(d.closed_at) AS DECIMAL(5,1)) END AS on_time_percent
FROM Service_Catalog sc
LEFT JOIN Service_Request sr ON sr.service_code = sc.service_code
LEFT JOIN decided d          ON d.request_id = sr.request_id
GROUP BY sc.service_code, sc.service_name, sc.target_days;
GO

PRINT '03_views.sql completed: 7 views created.';
GO
