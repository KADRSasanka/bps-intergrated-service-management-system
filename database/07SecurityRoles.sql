/* =====================================================================
   07_security_roles.sql  -  BPS_ServiceDBs

   DESIGN
   - Customers do NOT get SQL logins. The Laravel API signs in as one of 5 SQL logins,
     chosen by the role of the person using the app:
        bps_auth      login + Sanctum tokens + registration (no business tables)
        bps_customer  customer portal
        bps_clerk     Subject Clerk
        bps_officer   Officer
        bps_admin     Admin
   - Business tables are closed. People work through stored procedures and views.
     Procedures and views are owned by dbo, like the tables, so ownership chaining
     lets them touch tables the caller cannot. DENY on a table therefore does not
     break a procedure or view.
   - NIC and contact number are masked (Dynamic Data Masking) except for Admin and clerk.
   - Nobody can change or delete audit rows. Only the triggers write them.
   - bps_api (db_owner from 00_create_db.sql) stays for migrations and development only.
     It must not be used by the running API.
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- 1. Logins (server level) ---------- */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'bps_auth')
    CREATE LOGIN bps_auth     WITH PASSWORD = 'Bps_Auth#2026!',     DEFAULT_DATABASE = BPS_ServiceDB;  -- REPLACE
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'bps_customer')
    CREATE LOGIN bps_customer WITH PASSWORD = 'Bps_Customer#2026!', DEFAULT_DATABASE = BPS_ServiceDB;  -- REPLACE
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'bps_clerk')
    CREATE LOGIN bps_clerk    WITH PASSWORD = 'Bps_Clerk#2026!',    DEFAULT_DATABASE = BPS_ServiceDB;  -- REPLACE
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'bps_officer')
    CREATE LOGIN bps_officer  WITH PASSWORD = 'Bps_Officer#2026!',  DEFAULT_DATABASE = BPS_ServiceDB;  -- REPLACE
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'bps_admin')
    CREATE LOGIN bps_admin    WITH PASSWORD = 'Bps_Admin#2026!',    DEFAULT_DATABASE = BPS_ServiceDB;  -- REPLACE
GO

/* ---------- 2. Database users ---------- */
IF DATABASE_PRINCIPAL_ID('bps_auth')     IS NULL CREATE USER bps_auth     FOR LOGIN bps_auth;
IF DATABASE_PRINCIPAL_ID('bps_customer') IS NULL CREATE USER bps_customer FOR LOGIN bps_customer;
IF DATABASE_PRINCIPAL_ID('bps_clerk')    IS NULL CREATE USER bps_clerk    FOR LOGIN bps_clerk;
IF DATABASE_PRINCIPAL_ID('bps_officer')  IS NULL CREATE USER bps_officer  FOR LOGIN bps_officer;
IF DATABASE_PRINCIPAL_ID('bps_admin')    IS NULL CREATE USER bps_admin    FOR LOGIN bps_admin;
GO

/* ---------- 3. Database roles ---------- */
IF DATABASE_PRINCIPAL_ID('role_auth')     IS NULL CREATE ROLE role_auth;
IF DATABASE_PRINCIPAL_ID('role_customer') IS NULL CREATE ROLE role_customer;
IF DATABASE_PRINCIPAL_ID('role_clerk')    IS NULL CREATE ROLE role_clerk;
IF DATABASE_PRINCIPAL_ID('role_officer')  IS NULL CREATE ROLE role_officer;
IF DATABASE_PRINCIPAL_ID('role_admin')    IS NULL CREATE ROLE role_admin;
GO

ALTER ROLE role_auth     ADD MEMBER bps_auth;
ALTER ROLE role_customer ADD MEMBER bps_customer;
ALTER ROLE role_clerk    ADD MEMBER bps_clerk;
ALTER ROLE role_officer  ADD MEMBER bps_officer;
ALTER ROLE role_admin    ADD MEMBER bps_admin;
GO

/* ---------- 4. Customer-scoped view ----------
   The API runs  EXEC sp_set_session_context N'customer_id', <id>  on every request.
   With no customer_id set, the view returns no rows. */
CREATE OR ALTER VIEW dbo.vw_my_requests
AS
SELECT sr.request_id,
       sr.service_code,
       sc.service_name,
       sr.status,
       sr.submitted_date,
       sr.due_date,
       h.name           AS hall_name,
       hr.start_datetime,
       hr.end_datetime,
       hr.status        AS reservation_status
FROM Service_Request sr
JOIN Service_Catalog sc       ON sc.service_code = sr.service_code
LEFT JOIN Hall_Reservation hr ON hr.request_id = sr.request_id
LEFT JOIN Hall h              ON h.hall_id = hr.hall_id
WHERE sr.customer_id = TRY_CAST(SESSION_CONTEXT(N'customer_id') AS INT);
GO

/* Officer list for assigning requests. No password hash, so clerks need no access to User_Account. */
CREATE OR ALTER VIEW dbo.vw_officers
AS
SELECT user_id, username, designation
FROM User_Account
WHERE role = 'Officer' AND is_active = 1;
GO

/* ---------- 5. Mask NIC and contact number ---------- */
IF NOT EXISTS (SELECT 1 FROM sys.masked_columns WHERE object_id = OBJECT_ID('dbo.Customer') AND name = 'nic')
    ALTER TABLE dbo.Customer ALTER COLUMN nic ADD MASKED WITH (FUNCTION = 'partial(0,"XXXXXXXX",4)');
IF NOT EXISTS (SELECT 1 FROM sys.masked_columns WHERE object_id = OBJECT_ID('dbo.Customer') AND name = 'contact_no')
    ALTER TABLE dbo.Customer ALTER COLUMN contact_no ADD MASKED WITH (FUNCTION = 'partial(0,"XXXXXX",3)');
GO
GRANT UNMASK TO role_admin;
GRANT UNMASK TO role_clerk;
GO

/* ---------- 6. role_customer: portal ---------- */
GRANT SELECT  ON dbo.vw_hall_availability TO role_customer;
GRANT SELECT  ON dbo.vw_item_stock        TO role_customer;
GRANT SELECT  ON dbo.vw_my_requests       TO role_customer;
GRANT EXECUTE ON dbo.fn_item_available    TO role_customer;
GRANT EXECUTE ON dbo.sp_create_reservation TO role_customer;
GRANT EXECUTE ON dbo.sp_create_rental      TO role_customer;
GRANT EXECUTE ON dbo.sp_submit_request     TO role_customer;
-- reference data for the portal forms (nothing personal)
GRANT SELECT  ON dbo.Service_Catalog       TO role_customer;
GRANT SELECT  ON dbo.Licence_Type          TO role_customer;
GRANT SELECT  ON dbo.Hall_Photo            TO role_customer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Customer    TO role_customer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Payment     TO role_customer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.User_Account TO role_customer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Audit_Log   TO role_customer;
GO

/* ---------- 7. role_clerk: Subject Clerk ---------- */
GRANT EXECUTE ON dbo.fn_item_available      TO role_clerk;
GRANT EXECUTE ON dbo.sp_create_reservation  TO role_clerk;
GRANT EXECUTE ON dbo.sp_approve_reservation TO role_clerk;
GRANT EXECUTE ON dbo.sp_cancel_reservation  TO role_clerk;
GRANT EXECUTE ON dbo.sp_create_rental       TO role_clerk;
GRANT EXECUTE ON dbo.sp_issue_items         TO role_clerk;
GRANT EXECUTE ON dbo.sp_return_items        TO role_clerk;
GRANT EXECUTE ON dbo.sp_submit_request      TO role_clerk;
GRANT EXECUTE ON dbo.sp_record_payment      TO role_clerk;

GRANT SELECT ON dbo.vw_hall_availability    TO role_clerk;
GRANT SELECT ON dbo.vw_daily_bookings       TO role_clerk;
GRANT SELECT ON dbo.vw_current_rentals      TO role_clerk;
GRANT SELECT ON dbo.vw_overdue_items        TO role_clerk;
GRANT SELECT ON dbo.vw_item_stock           TO role_clerk;
GRANT SELECT ON dbo.vw_requests_over_target TO role_clerk;
GRANT SELECT ON dbo.vw_officers             TO role_clerk;

-- read-only lists; all changes go through the procedures
GRANT SELECT ON dbo.Hall_Photo            TO role_clerk;
GRANT SELECT ON dbo.Damage_Record         TO role_clerk;
GRANT SELECT ON dbo.Service_Request       TO role_clerk;
GRANT SELECT ON dbo.Hall_Reservation      TO role_clerk;
GRANT SELECT ON dbo.Item_Rental           TO role_clerk;
GRANT SELECT ON dbo.Rental_Line           TO role_clerk;
GRANT SELECT ON dbo.Payment               TO role_clerk;
GRANT SELECT ON dbo.Licence_Application   TO role_clerk;
GRANT SELECT ON dbo.Complaint_Request     TO role_clerk;
GRANT SELECT ON dbo.Request_Approval      TO role_clerk;
GRANT SELECT ON dbo.Hall                  TO role_clerk;
GRANT SELECT ON dbo.Item                  TO role_clerk;
GRANT SELECT ON dbo.Service_Catalog       TO role_clerk;
GRANT SELECT ON dbo.Licence_Type          TO role_clerk;
GRANT SELECT, INSERT, UPDATE ON dbo.Customer TO role_clerk;   -- registers walk-in customers

DENY SELECT, INSERT, UPDATE, DELETE ON dbo.User_Account TO role_clerk;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Audit_Log    TO role_clerk;
GO

/* ---------- 8. role_officer ---------- */
GRANT EXECUTE ON dbo.sp_advance_request     TO role_officer;
GRANT SELECT  ON dbo.vw_requests_over_target TO role_officer;
GRANT SELECT  ON dbo.Service_Request     TO role_officer;
GRANT SELECT  ON dbo.Licence_Application TO role_officer;
GRANT SELECT  ON dbo.Complaint_Request   TO role_officer;
GRANT SELECT  ON dbo.Request_Approval    TO role_officer;
GRANT SELECT  ON dbo.Service_Catalog     TO role_officer;
GRANT SELECT  ON dbo.Licence_Type        TO role_officer;
GRANT SELECT  ON dbo.Customer            TO role_officer;     -- NIC and phone stay masked
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.User_Account TO role_officer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Audit_Log    TO role_officer;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.Payment      TO role_officer;
GO

/* ---------- 9. role_admin ---------- */
GRANT SELECT  ON SCHEMA::dbo TO role_admin;     -- every table and view, including reports and audit
GRANT EXECUTE ON SCHEMA::dbo TO role_admin;     -- every procedure and function

GRANT INSERT, UPDATE ON dbo.User_Account    TO role_admin;
GRANT INSERT, UPDATE ON dbo.Customer        TO role_admin;
GRANT INSERT, UPDATE ON dbo.Hall            TO role_admin;
GRANT INSERT, UPDATE ON dbo.Hall_Photo      TO role_admin;
GRANT INSERT, UPDATE ON dbo.Item            TO role_admin;
GRANT INSERT, UPDATE ON dbo.Service_Catalog TO role_admin;
GRANT INSERT, UPDATE ON dbo.Licence_Type    TO role_admin;
GO

/* ---------- 10. role_auth: login, tokens, registration ---------- */
GRANT SELECT, INSERT ON dbo.User_Account TO role_auth;
GRANT SELECT, INSERT ON dbo.Customer     TO role_auth;
DENY  INSERT, UPDATE, DELETE ON dbo.Audit_Log TO role_auth;
GO

/* ---------- 11. Nobody changes or deletes records directly (audit stays intact; use is_active, Cancelled) ---------- */
DENY INSERT, UPDATE, DELETE ON dbo.Audit_Log TO role_admin;
DENY DELETE ON SCHEMA::dbo TO role_customer;
DENY DELETE ON SCHEMA::dbo TO role_clerk;
DENY DELETE ON SCHEMA::dbo TO role_officer;
DENY DELETE ON SCHEMA::dbo TO role_admin;
GO

/* ---------- 12. Laravel Sanctum token table (exists after `php artisan migrate`) ---------- */
IF OBJECT_ID('dbo.personal_access_tokens') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.personal_access_tokens TO role_auth;
    PRINT 'Sanctum token table grants applied.';
END
ELSE
    PRINT 'personal_access_tokens not found yet. Run php artisan migrate, then re-run this file.';
GO

PRINT '07_security_roles.sql completed: 5 logins, 5 roles.';
GO
