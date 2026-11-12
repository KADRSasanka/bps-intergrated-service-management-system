/* =====================================================================
   05b_trigger_tests.sql  -  evidence for the report
   Run once on a dev database AFTER 01 to 05. It creates a little test data
   (dates in 2031) and then tries to break each rule. Expected result of each
   test is printed in the Messages tab. Re-run 01 to 05 to reset before running again.
   Take screenshots of the Messages tab and the last two result grids.
   ===================================================================== */
USE BPS_ServiceDB;
GO

SET NOCOUNT ON;

/* ---------- Setup ---------- */
IF NOT EXISTS (SELECT 1 FROM Service_Catalog WHERE service_code = 'BPS/5')
    INSERT INTO Service_Catalog (service_code, service_name, target_days, fee) VALUES ('BPS/5', 'Hall Reservation', 3, 0);
IF NOT EXISTS (SELECT 1 FROM Service_Catalog WHERE service_code = 'BPS/8')
    INSERT INTO Service_Catalog (service_code, service_name, target_days, fee) VALUES ('BPS/8', 'Item Rental', 2, 0);
IF NOT EXISTS (SELECT 1 FROM Customer WHERE nic = '199912345678')
    INSERT INTO Customer (full_name, nic, contact_no) VALUES ('Trigger Test Customer', '199912345678', '0771234567');
IF NOT EXISTS (SELECT 1 FROM Hall WHERE name = 'Trigger Test Hall')
    INSERT INTO Hall (name, capacity, rental_charge) VALUES ('Trigger Test Hall', 100, 5000);
IF NOT EXISTS (SELECT 1 FROM Item WHERE name = 'Trigger Test Chair')
    INSERT INTO Item (name, category, total_quantity, rental_charge) VALUES ('Trigger Test Chair', 'Furniture', 10, 20);

DECLARE @cust INT = (SELECT customer_id FROM Customer WHERE nic = '199912345678');
DECLARE @hall INT = (SELECT hall_id FROM Hall WHERE name = 'Trigger Test Hall');
DECLARE @item INT = (SELECT item_id FROM Item WHERE name = 'Trigger Test Chair');
DECLARE @r1 INT, @r2 INT, @r3 INT, @rent INT, @lines NVARCHAR(MAX);

-- r1: approved and confirmed (with advance) 09:00-13:00
EXEC dbo.sp_create_reservation @customer_id = @cust, @hall_id = @hall, @purpose = N'Test A', @expected_crowd = 50,
     @start_datetime = '2031-01-10 09:00', @end_datetime = '2031-01-10 13:00', @request_id = @r1 OUTPUT;
EXEC dbo.sp_approve_reservation @request_id = @r1, @user_id = NULL, @advance_amount = 1000;

-- r2: overlaps r1 (11:00-15:00), still Pending
EXEC dbo.sp_create_reservation @customer_id = @cust, @hall_id = @hall, @purpose = N'Test B', @expected_crowd = 50,
     @start_datetime = '2031-01-10 11:00', @end_datetime = '2031-01-10 15:00', @request_id = @r2 OUTPUT;

-- r3: free day, still Pending
EXEC dbo.sp_create_reservation @customer_id = @cust, @hall_id = @hall, @purpose = N'Test C', @expected_crowd = 50,
     @start_datetime = '2031-02-01 09:00', @end_datetime = '2031-02-01 13:00', @request_id = @r3 OUTPUT;

-- rental asking for 50 chairs while only 10 exist
SET @lines = N'[{"item_id":' + CAST(@item AS NVARCHAR(10)) + N',"quantity":50}]';
EXEC dbo.sp_create_rental @customer_id = @cust, @purpose = N'Test rental', @issue_date = '2031-03-01',
     @due_date = '2031-03-03', @lines_json = @lines, @request_id = @rent OUTPUT;

/* ---------- T1: overlapping booking blocked (expect 50001 twice) ---------- */
PRINT '--- T1a: procedure approves overlapping reservation ---';
BEGIN TRY
    EXEC dbo.sp_approve_reservation @request_id = @r2, @user_id = NULL;
    PRINT 'FAIL: overlap was allowed';
END TRY
BEGIN CATCH
    PRINT 'Blocked: ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

PRINT '--- T1b: direct UPDATE bypassing the procedure (trigger backstop) ---';
BEGIN TRY
    UPDATE Hall_Reservation SET status = 'Approved' WHERE request_id = @r2;
    PRINT 'FAIL: overlap was allowed';
END TRY
BEGIN CATCH
    PRINT 'Blocked: ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

/* ---------- T2: stock over-issue blocked (expect 50003 twice) ---------- */
PRINT '--- T2a: procedure issues 50 chairs, stock is 10 ---';
BEGIN TRY
    EXEC dbo.sp_issue_items @request_id = @rent, @user_id = NULL;
    PRINT 'FAIL: over-issue was allowed';
END TRY
BEGIN CATCH
    PRINT 'Blocked: ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

PRINT '--- T2b: direct UPDATE of quantity_issued (trigger backstop) ---';
BEGIN TRY
    UPDATE Rental_Line SET quantity_issued = 50 WHERE rental_id = @rent;
    PRINT 'FAIL: over-issue was allowed';
END TRY
BEGIN CATCH
    PRINT 'Blocked: ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

/* ---------- T3: confirm without advance payment blocked (expect 50004) ---------- */
PRINT '--- T3: direct UPDATE to Confirmed with no advance payment ---';
BEGIN TRY
    UPDATE Hall_Reservation SET status = 'Confirmed' WHERE request_id = @r3;
    PRINT 'FAIL: confirmed without advance';
END TRY
BEGIN CATCH
    PRINT 'Blocked: ' + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ' - ' + ERROR_MESSAGE();
END CATCH

/* ---------- T4: due date set from the Service Catalog ---------- */
PRINT '--- T4: due_date = submitted_date + target_days (screenshot the grid) ---';
SELECT sr.request_id, sr.service_code, sc.target_days, sr.submitted_date, sr.due_date
FROM Service_Request sr
JOIN Service_Catalog sc ON sc.service_code = sr.service_code
WHERE sr.request_id IN (@r1, @r2, @r3, @rent);

/* ---------- T5: audit log (screenshot the grid) ---------- */
PRINT '--- T5: latest audit rows ---';
SELECT TOP (10) log_id, table_name, record_id, action, user_id, old_value, new_value, changed_at
FROM Audit_Log
ORDER BY log_id DESC;
GO
