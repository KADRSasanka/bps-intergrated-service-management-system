/* =====================================================================
   07b_security_tests.sql  -  evidence for the report
   Each test impersonates one database user. "Blocked" lines with error 229 or 297
   (permission denied) are the expected result. Screenshot the Messages tab and grids.
   ===================================================================== */
USE BPS_ServiceDB;
GO
SET NOCOUNT ON;

/* ---------- Customer ---------- */
PRINT '=== bps_customer ===';
EXECUTE AS USER = 'bps_customer';

BEGIN TRY
    SELECT TOP (1) * FROM dbo.Customer;
    PRINT 'FAIL: customer read the Customer table';
END TRY
BEGIN CATCH
    PRINT 'Blocked (Customer table): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    SELECT TOP (1) * FROM dbo.Audit_Log;
    PRINT 'FAIL: customer read the audit log';
END TRY
BEGIN CATCH
    PRINT 'Blocked (Audit_Log): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    EXEC dbo.sp_advance_request @request_id = 1, @officer_id = 1, @decision = 'Approved';
    PRINT 'FAIL: customer ran an officer procedure';
END TRY
BEGIN CATCH
    PRINT 'Blocked (sp_advance_request): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    DELETE FROM dbo.Hall_Reservation;
    PRINT 'FAIL: customer deleted reservations';
END TRY
BEGIN CATCH
    PRINT 'Blocked (DELETE): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    SELECT COUNT(*) AS halls_visible_to_customer FROM dbo.vw_hall_availability;
    PRINT 'Allowed: vw_hall_availability';
END TRY
BEGIN CATCH
    PRINT 'FAIL: ' + ERROR_MESSAGE();
END CATCH

-- customer-scoped view: no context = no rows
EXEC sys.sp_set_session_context @key = N'customer_id', @value = NULL;
SELECT COUNT(*) AS my_requests_without_context FROM dbo.vw_my_requests;
REVERT;
GO

/* ---------- Officer: masked NIC ---------- */
PRINT '=== bps_officer (NIC and phone should be masked) ===';
EXECUTE AS USER = 'bps_officer';
SELECT TOP (3) customer_id, full_name, nic, contact_no FROM dbo.Customer ORDER BY customer_id;
REVERT;
GO

/* ---------- Clerk: unmasked NIC, but no direct writes to reservations ---------- */
PRINT '=== bps_clerk (NIC and phone visible) ===';
EXECUTE AS USER = 'bps_clerk';
SELECT TOP (3) customer_id, full_name, nic, contact_no FROM dbo.Customer ORDER BY customer_id;

BEGIN TRY
    UPDATE dbo.Hall_Reservation SET status = 'Confirmed';
    PRINT 'FAIL: clerk updated reservations directly';
END TRY
BEGIN CATCH
    PRINT 'Blocked (direct UPDATE): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    SELECT TOP (1) * FROM dbo.User_Account;
    PRINT 'FAIL: clerk read user accounts';
END TRY
BEGIN CATCH
    PRINT 'Blocked (User_Account): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH
REVERT;
GO

/* ---------- Admin: can read the audit log but not change it ---------- */
PRINT '=== bps_admin ===';
EXECUTE AS USER = 'bps_admin';

BEGIN TRY
    SELECT COUNT(*) AS audit_rows_visible_to_admin FROM dbo.Audit_Log;
    PRINT 'Allowed: admin reads Audit_Log';
END TRY
BEGIN CATCH
    PRINT 'FAIL: ' + ERROR_MESSAGE();
END CATCH

BEGIN TRY
    UPDATE dbo.Audit_Log SET action = 'D';
    PRINT 'FAIL: admin changed the audit log';
END TRY
BEGIN CATCH
    PRINT 'Blocked (Audit_Log UPDATE): ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH
REVERT;
GO
