/* =====================================================================
   04_procedures.sql  -  BPS_ServiceDB

   ERROR CODES (THROW). The Laravel API maps these to HTTP responses:
     50001  Hall already booked for this period            -> 409
     50002  Expected crowd exceeds hall capacity           -> 422
     50003  Not enough stock for one or more items         -> 409
     50004  Advance payment required to confirm            -> 422
     50005  Invalid status for this action                 -> 409
     50006  Return/damage quantity exceeds quantity issued -> 422
     50007  N.B.R.O report must be recorded first          -> 422
     50008  Record not found or inactive                   -> 404
     50010  Invalid date or time range                     -> 422
     50011  Officer not allowed / not this officer's step   -> 403
     50012  Invalid input                                  -> 422

   Procedures:
     sp_create_reservation   sp_approve_reservation   sp_cancel_reservation
     sp_create_rental        sp_issue_items           sp_return_items
     sp_submit_request       sp_advance_request       sp_record_payment
   Function:
     fn_item_available(item, from, to, exclude_request)

   Concurrency: approving a reservation locks the Hall row (UPDLOCK, HOLDLOCK);
   issuing items locks the Item rows. Two sessions asking for the same last
   slot or last chairs run one after the other. The overlap and stock triggers
   (05_triggers.sql) are the backstop.
   Overlap rule: new_start < existing_end AND new_end > existing_start,
   counting only status IN ('Approved','Confirmed') (matches the filtered index).
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- Function: items free for a date range ---------- */
CREATE OR ALTER FUNCTION dbo.fn_item_available
    (@item_id INT, @from DATE, @to DATE, @exclude_request_id INT)
RETURNS INT
AS
BEGIN
    DECLARE @total INT, @committed INT;

    SELECT @total = total_quantity FROM Item WHERE item_id = @item_id AND is_active = 1;
    IF @total IS NULL RETURN 0;

    -- Approved/Issued rentals hold stock. An Issued rental still holds it
    -- after its due date until the items are returned.
    SELECT @committed = ISNULL(SUM(rl.quantity_requested - rl.quantity_returned), 0)
    FROM Rental_Line rl
    JOIN Item_Rental ir ON ir.request_id = rl.rental_id
    WHERE rl.item_id = @item_id
      AND ir.status IN ('Approved','Issued')
      AND (@exclude_request_id IS NULL OR ir.request_id <> @exclude_request_id)
      AND ir.issue_date <= @to
      AND (ir.due_date >= @from OR ir.status = 'Issued');

    RETURN CASE WHEN @total - @committed < 0 THEN 0 ELSE @total - @committed END;
END
GO

/* ---------- 1. Create a hall reservation request (status Pending, holds nothing) ---------- */
CREATE OR ALTER PROCEDURE dbo.sp_create_reservation
    @customer_id          INT,
    @hall_id              INT,
    @purpose              NVARCHAR(200),
    @expected_crowd       INT,
    @start_datetime       DATETIME2(0),
    @end_datetime         DATETIME2(0),
    @special_requirements NVARCHAR(500) = NULL,
    @user_id              INT = NULL,
    @request_id           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        IF @end_datetime <= @start_datetime THROW 50010, 'End time must be after start time.', 1;
        IF NOT EXISTS (SELECT 1 FROM Customer WHERE customer_id = @customer_id)
            THROW 50008, 'Customer not found.', 1;

        DECLARE @capacity INT;
        SELECT @capacity = capacity FROM Hall WHERE hall_id = @hall_id AND is_active = 1;
        IF @capacity IS NULL THROW 50008, 'Hall not found or inactive.', 1;
        IF @expected_crowd > @capacity THROW 50002, 'Expected crowd exceeds hall capacity.', 1;

        BEGIN TRANSACTION;
            INSERT INTO Service_Request (service_code, customer_id, status, created_by)
            VALUES ('BPS/5', @customer_id, 'Pending', @user_id);
            SET @request_id = SCOPE_IDENTITY();

            INSERT INTO Hall_Reservation (request_id, hall_id, purpose, expected_crowd,
                                          start_datetime, end_datetime, special_requirements, status)
            VALUES (@request_id, @hall_id, @purpose, @expected_crowd,
                    @start_datetime, @end_datetime, @special_requirements, 'Pending');
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 2. Approve a reservation; with an advance amount it is also Confirmed ----------
   Pending  -> Approved  (hall is now blocked; overlap checked under a hall lock)
   Approved -> Confirmed (advance payment recorded in the same transaction) */
CREATE OR ALTER PROCEDURE dbo.sp_approve_reservation
    @request_id     INT,
    @user_id        INT,
    @advance_amount DECIMAL(10,2) = NULL,
    @receipt_no     VARCHAR(30)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        DECLARE @hall_id INT, @start DATETIME2(0), @end DATETIME2(0), @status VARCHAR(10);

        BEGIN TRANSACTION;
            SELECT @hall_id = hall_id, @start = start_datetime, @end = end_datetime, @status = status
            FROM Hall_Reservation WITH (UPDLOCK)
            WHERE request_id = @request_id;

            IF @hall_id IS NULL THROW 50008, 'Reservation not found.', 1;
            IF @status NOT IN ('Pending','Approved')
                THROW 50005, 'Only Pending or Approved reservations can be approved or confirmed.', 1;
            IF @status = 'Approved' AND @advance_amount IS NULL
                THROW 50004, 'Advance payment is required to confirm the reservation.', 1;

            -- serialize everyone working on this hall
            SELECT @hall_id = hall_id FROM Hall WITH (UPDLOCK, HOLDLOCK) WHERE hall_id = @hall_id;

            IF @status = 'Pending'
            BEGIN
                IF EXISTS (SELECT 1 FROM Hall_Reservation
                           WHERE hall_id = @hall_id
                             AND request_id <> @request_id
                             AND status IN ('Approved','Confirmed')
                             AND start_datetime < @end
                             AND end_datetime   > @start)
                    THROW 50001, 'The hall is already booked for this period.', 1;

                UPDATE Hall_Reservation SET status = 'Approved' WHERE request_id = @request_id;
                UPDATE Service_Request  SET status = 'Approved' WHERE request_id = @request_id;
            END

            IF @advance_amount IS NOT NULL
            BEGIN
                INSERT INTO Payment (request_id, payment_type, amount, receipt_no, received_by)
                VALUES (@request_id, 'Advance', @advance_amount, @receipt_no, @user_id);

                UPDATE Hall_Reservation SET status = 'Confirmed' WHERE request_id = @request_id;
            END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 3. Cancel a reservation ---------- */
CREATE OR ALTER PROCEDURE dbo.sp_cancel_reservation
    @request_id INT,
    @user_id    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        DECLARE @status VARCHAR(10);

        BEGIN TRANSACTION;
            SELECT @status = status FROM Hall_Reservation WITH (UPDLOCK) WHERE request_id = @request_id;

            IF @status IS NULL THROW 50008, 'Reservation not found.', 1;
            IF @status = 'Cancelled' THROW 50005, 'The reservation is already cancelled.', 1;

            UPDATE Hall_Reservation SET status = 'Cancelled' WHERE request_id = @request_id;
            UPDATE Service_Request  SET status = 'Cancelled' WHERE request_id = @request_id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 4. Create an item rental request (status Pending, holds no stock) ----------
   @lines_json example: [{"item_id":1,"quantity":50},{"item_id":4,"quantity":2}] */
CREATE OR ALTER PROCEDURE dbo.sp_create_rental
    @customer_id INT,
    @purpose     NVARCHAR(200),
    @issue_date  DATE,
    @due_date    DATE,
    @lines_json  NVARCHAR(MAX),
    @user_id     INT = NULL,
    @request_id  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        IF @due_date < @issue_date THROW 50010, 'Due date cannot be before the issue date.', 1;
        IF NOT EXISTS (SELECT 1 FROM Customer WHERE customer_id = @customer_id)
            THROW 50008, 'Customer not found.', 1;
        IF ISJSON(@lines_json) <> 1 THROW 50012, 'Item lines must be a valid JSON array.', 1;

        DECLARE @lines TABLE (item_id INT, quantity INT);
        INSERT INTO @lines (item_id, quantity)
        SELECT item_id, SUM(quantity)
        FROM OPENJSON(@lines_json) WITH (item_id INT '$.item_id', quantity INT '$.quantity')
        GROUP BY item_id;

        IF NOT EXISTS (SELECT 1 FROM @lines) THROW 50012, 'At least one item is required.', 1;
        IF EXISTS (SELECT 1 FROM @lines WHERE quantity IS NULL OR quantity <= 0)
            THROW 50012, 'Each item needs a quantity greater than zero.', 1;
        IF EXISTS (SELECT 1 FROM @lines l
                   LEFT JOIN Item i ON i.item_id = l.item_id AND i.is_active = 1
                   WHERE i.item_id IS NULL)
            THROW 50008, 'One or more items were not found.', 1;

        BEGIN TRANSACTION;
            INSERT INTO Service_Request (service_code, customer_id, status, created_by)
            VALUES ('BPS/8', @customer_id, 'Pending', @user_id);
            SET @request_id = SCOPE_IDENTITY();

            INSERT INTO Item_Rental (request_id, purpose, issue_date, due_date, status)
            VALUES (@request_id, @purpose, @issue_date, @due_date, 'Pending');

            INSERT INTO Rental_Line (rental_id, item_id, quantity_requested)
            SELECT @request_id, item_id, quantity FROM @lines;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 5. Issue the requested items (approves and issues in one step) ---------- */
CREATE OR ALTER PROCEDURE dbo.sp_issue_items
    @request_id INT,
    @user_id    INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        DECLARE @status VARCHAR(10), @lock INT;

        BEGIN TRANSACTION;
            SELECT @status = status FROM Item_Rental WITH (UPDLOCK) WHERE request_id = @request_id;

            IF @status IS NULL THROW 50008, 'Rental not found.', 1;
            IF @status NOT IN ('Pending','Approved')
                THROW 50005, 'Only Pending or Approved rentals can be issued.', 1;

            -- lock the item rows so two clerks cannot take the last chairs together
            SELECT @lock = COUNT(*)
            FROM Item WITH (UPDLOCK, HOLDLOCK)
            WHERE item_id IN (SELECT item_id FROM Rental_Line WHERE rental_id = @request_id);

            IF EXISTS (SELECT 1
                       FROM Rental_Line rl
                       JOIN Item_Rental ir ON ir.request_id = rl.rental_id
                       WHERE rl.rental_id = @request_id
                         AND dbo.fn_item_available(rl.item_id, ir.issue_date, ir.due_date, @request_id)
                             < rl.quantity_requested)
                THROW 50003, 'Not enough stock for one or more items.', 1;

            UPDATE Rental_Line SET quantity_issued = quantity_requested WHERE rental_id = @request_id;
            UPDATE Item_Rental SET status = 'Issued'         WHERE request_id = @request_id;
            UPDATE Service_Request SET status = 'InProgress' WHERE request_id = @request_id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 6. Return items (and record damaged or lost items) ----------
   @returns_json example:
   [{"item_id":1,"returned":48,"damaged":2,"action":"PayValue","amount":1500.00}]
   "returned" = units brought back. "damaged" = units damaged or lost and NOT brought back.
   A line is closed when returned + damaged = issued. Rental becomes Returned when all lines are closed. */
CREATE OR ALTER PROCEDURE dbo.sp_return_items
    @request_id   INT,
    @user_id      INT,
    @returns_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        IF ISJSON(@returns_json) <> 1 THROW 50012, 'Returns must be a valid JSON array.', 1;

        DECLARE @r TABLE (item_id INT, returned INT, damaged INT, action VARCHAR(10), amount DECIMAL(10,2));
        INSERT INTO @r (item_id, returned, damaged, action, amount)
        SELECT item_id, ISNULL(returned, 0), ISNULL(damaged, 0), action, amount
        FROM OPENJSON(@returns_json)
             WITH (item_id INT '$.item_id', returned INT '$.returned', damaged INT '$.damaged',
                   action VARCHAR(10) '$.action', amount DECIMAL(10,2) '$.amount');

        IF NOT EXISTS (SELECT 1 FROM @r) THROW 50012, 'At least one item line is required.', 1;
        IF EXISTS (SELECT item_id FROM @r GROUP BY item_id HAVING COUNT(*) > 1)
            THROW 50012, 'Each item can appear only once.', 1;
        IF EXISTS (SELECT 1 FROM @r WHERE returned < 0 OR damaged < 0 OR (returned = 0 AND damaged = 0))
            THROW 50012, 'Quantities must be zero or more, and not both zero.', 1;
        IF EXISTS (SELECT 1 FROM @r
                   WHERE damaged > 0
                     AND (action IS NULL OR action NOT IN ('Replace','PayValue')
                          OR (action = 'PayValue' AND amount IS NULL)))
            THROW 50012, 'Damaged items need an action (Replace or PayValue); PayValue needs an amount.', 1;

        DECLARE @status VARCHAR(10);

        BEGIN TRANSACTION;
            SELECT @status = status FROM Item_Rental WITH (UPDLOCK) WHERE request_id = @request_id;

            IF @status IS NULL THROW 50008, 'Rental not found.', 1;
            IF @status <> 'Issued' THROW 50005, 'Only Issued rentals can have items returned.', 1;

            IF EXISTS (SELECT 1 FROM @r r
                       LEFT JOIN Rental_Line rl ON rl.rental_id = @request_id AND rl.item_id = r.item_id
                       WHERE rl.item_id IS NULL)
                THROW 50008, 'An item in the list is not part of this rental.', 1;

            IF EXISTS (SELECT 1
                       FROM @r r
                       JOIN Rental_Line rl ON rl.rental_id = @request_id AND rl.item_id = r.item_id
                       WHERE rl.quantity_returned
                             + ISNULL((SELECT SUM(d.quantity) FROM Damage_Record d
                                       WHERE d.rental_id = rl.rental_id AND d.item_id = rl.item_id), 0)
                             + r.returned + r.damaged > rl.quantity_issued)
                THROW 50006, 'Returned and damaged quantity exceeds the quantity issued.', 1;

            UPDATE rl
            SET rl.quantity_returned = rl.quantity_returned + r.returned
            FROM Rental_Line rl
            JOIN @r r ON r.item_id = rl.item_id
            WHERE rl.rental_id = @request_id;

            INSERT INTO Damage_Record (rental_id, item_id, quantity, action_taken, amount)
            SELECT @request_id, item_id, damaged, action, amount FROM @r WHERE damaged > 0;

            INSERT INTO Payment (request_id, payment_type, amount, received_by)
            SELECT @request_id, 'Compensation', SUM(amount), @user_id
            FROM @r
            WHERE damaged > 0 AND action = 'PayValue'
            HAVING SUM(amount) > 0;

            -- close the rental when every line is fully accounted for
            IF NOT EXISTS (SELECT 1 FROM Rental_Line rl
                           WHERE rl.rental_id = @request_id
                             AND rl.quantity_returned
                                 + ISNULL((SELECT SUM(d.quantity) FROM Damage_Record d
                                           WHERE d.rental_id = rl.rental_id AND d.item_id = rl.item_id), 0)
                                 < rl.quantity_issued)
            BEGIN
                UPDATE Item_Rental     SET status = 'Returned'  WHERE request_id = @request_id;
                UPDATE Service_Request SET status = 'Completed' WHERE request_id = @request_id;
            END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 7. Submit a licence / certificate / approval / complaint / street light request ----------
   BPS/1-4 need @licence_type_id. BPS/6 and BPS/7 need @category, @location, @description.
   BPS/5 and BPS/8 have their own procedures.
   @approval_steps_json (optional): [{"step":1,"officer_id":5},{"step":2,"officer_id":8}] */
CREATE OR ALTER PROCEDURE dbo.sp_submit_request
    @service_code         VARCHAR(10),
    @customer_id          INT,
    @user_id              INT = NULL,
    @licence_type_id      INT = NULL,
    @category             VARCHAR(12) = NULL,
    @location             NVARCHAR(250) = NULL,
    @description          NVARCHAR(1000) = NULL,
    @received_by          VARCHAR(10) = 'Online',
    @assigned_officer_id  INT = NULL,
    @approval_steps_json  NVARCHAR(MAX) = NULL,
    @request_id           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        IF @service_code NOT IN ('BPS/1','BPS/2','BPS/3','BPS/4','BPS/6','BPS/7')
            THROW 50012, 'Use the dedicated procedure for hall reservations and item rentals.', 1;
        IF NOT EXISTS (SELECT 1 FROM Service_Catalog WHERE service_code = @service_code)
            THROW 50008, 'Service not found in the service catalog.', 1;
        IF NOT EXISTS (SELECT 1 FROM Customer WHERE customer_id = @customer_id)
            THROW 50008, 'Customer not found.', 1;

        DECLARE @is_licence BIT = CASE WHEN @service_code IN ('BPS/1','BPS/2','BPS/3','BPS/4') THEN 1 ELSE 0 END;

        IF @is_licence = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Licence_Type
                           WHERE licence_type_id = @licence_type_id AND service_code = @service_code)
                THROW 50012, 'A valid licence type for this service is required.', 1;
        END
        ELSE
        BEGIN
            IF @category IS NULL OR @location IS NULL OR @description IS NULL
                THROW 50012, 'Category, location and description are required.', 1;
        END

        IF @approval_steps_json IS NOT NULL AND ISJSON(@approval_steps_json) <> 1
            THROW 50012, 'Approval steps must be a valid JSON array.', 1;

        BEGIN TRANSACTION;
            INSERT INTO Service_Request (service_code, customer_id, status, assigned_officer_id, created_by)
            VALUES (@service_code, @customer_id, 'Pending', @assigned_officer_id, @user_id);
            SET @request_id = SCOPE_IDENTITY();

            IF @is_licence = 1
                INSERT INTO Licence_Application (request_id, licence_type_id)
                VALUES (@request_id, @licence_type_id);
            ELSE
                INSERT INTO Complaint_Request (request_id, category, location, description, received_by)
                VALUES (@request_id, @category, @location, @description, @received_by);

            IF @approval_steps_json IS NOT NULL
                INSERT INTO Request_Approval (request_id, officer_id, step_no)
                SELECT @request_id, officer_id, step
                FROM OPENJSON(@approval_steps_json) WITH (step INT '$.step', officer_id INT '$.officer_id');
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 8. Record an officer's decision and move the request forward ----------
   Steps are taken in step_no order. If a request has no steps yet, the assigned
   officer's decision becomes step 1.
   BPS/1-4: all steps approved -> Approved (N.B.R.O report must be recorded first when the type needs it).
   BPS/6-7: all steps approved -> Completed (resolved_date set).
   Any rejection -> Rejected. */
CREATE OR ALTER PROCEDURE dbo.sp_advance_request
    @request_id        INT,
    @officer_id        INT,
    @decision          VARCHAR(10),
    @remarks           NVARCHAR(500) = NULL,
    @nbro_report_no    VARCHAR(40) = NULL,
    @nbro_report_date  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @officer_id;

        IF @decision NOT IN ('Approved','Rejected') THROW 50012, 'Decision must be Approved or Rejected.', 1;
        IF NOT EXISTS (SELECT 1 FROM User_Account WHERE user_id = @officer_id AND role = 'Officer' AND is_active = 1)
            THROW 50011, 'Only an active Officer can record a decision.', 1;

        DECLARE @status VARCHAR(12), @service VARCHAR(10), @assigned INT,
                @step_id INT, @step_officer INT, @new_status VARCHAR(12);

        BEGIN TRANSACTION;
            SELECT @status = status, @service = service_code, @assigned = assigned_officer_id
            FROM Service_Request WITH (UPDLOCK)
            WHERE request_id = @request_id;

            IF @status IS NULL THROW 50008, 'Request not found.', 1;
            IF @service NOT IN ('BPS/1','BPS/2','BPS/3','BPS/4','BPS/6','BPS/7')
                THROW 50012, 'This request type does not use officer decisions.', 1;
            IF @status NOT IN ('Pending','InProgress')
                THROW 50005, 'This request is already closed.', 1;

            -- no steps defined: the assigned officer becomes step 1
            IF NOT EXISTS (SELECT 1 FROM Request_Approval WHERE request_id = @request_id)
            BEGIN
                IF @assigned IS NULL OR @assigned <> @officer_id
                    THROW 50011, 'This request is assigned to a different officer.', 1;
                INSERT INTO Request_Approval (request_id, officer_id, step_no)
                VALUES (@request_id, @officer_id, 1);
            END

            SELECT TOP (1) @step_id = approval_id, @step_officer = officer_id
            FROM Request_Approval
            WHERE request_id = @request_id AND decision = 'Pending'
            ORDER BY step_no;

            IF @step_id IS NULL THROW 50005, 'There is no pending approval step.', 1;
            IF @step_officer <> @officer_id THROW 50011, 'The current step is assigned to a different officer.', 1;

            -- N.B.R.O report rule (licences, certificates, approvals only)
            IF @service IN ('BPS/1','BPS/2','BPS/3','BPS/4')
            BEGIN
                IF @nbro_report_no IS NOT NULL
                BEGIN
                    IF @nbro_report_date IS NULL THROW 50012, 'N.B.R.O report date is required with the report number.', 1;
                    UPDATE Licence_Application
                    SET nbro_report_no = @nbro_report_no, nbro_report_date = @nbro_report_date
                    WHERE request_id = @request_id;
                END

                IF @decision = 'Approved'
                   AND EXISTS (SELECT 1
                               FROM Licence_Application la
                               JOIN Licence_Type lt ON lt.licence_type_id = la.licence_type_id
                               WHERE la.request_id = @request_id
                                 AND lt.requires_nbro = 1
                                 AND la.nbro_report_no IS NULL)
                    THROW 50007, 'The N.B.R.O report must be recorded before approval.', 1;
            END

            UPDATE Request_Approval
            SET decision = @decision, decided_at = SYSUTCDATETIME(), remarks = @remarks
            WHERE approval_id = @step_id;

            IF @decision = 'Rejected'
                SET @new_status = 'Rejected';
            ELSE IF EXISTS (SELECT 1 FROM Request_Approval WHERE request_id = @request_id AND decision = 'Pending')
                SET @new_status = 'InProgress';
            ELSE IF @service IN ('BPS/6','BPS/7')
                SET @new_status = 'Completed';
            ELSE
                SET @new_status = 'Approved';

            UPDATE Service_Request SET status = @new_status WHERE request_id = @request_id;

            IF @new_status = 'Completed'
                UPDATE Complaint_Request SET resolved_date = SYSUTCDATETIME() WHERE request_id = @request_id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- 9. Record a payment (fees, final payment, compensation) ----------
   Advance payments for halls are recorded by sp_approve_reservation. */
CREATE OR ALTER PROCEDURE dbo.sp_record_payment
    @request_id   INT,
    @payment_type VARCHAR(12),
    @amount       DECIMAL(10,2),
    @receipt_no   VARCHAR(30) = NULL,
    @user_id      INT,
    @payment_id   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        EXEC sys.sp_set_session_context @key = N'user_id', @value = @user_id;

        IF @payment_type NOT IN ('Final','Fee','Compensation')
            THROW 50012, 'Payment type must be Final, Fee or Compensation.', 1;
        IF @amount IS NULL OR @amount <= 0 THROW 50012, 'Amount must be greater than zero.', 1;
        IF NOT EXISTS (SELECT 1 FROM Service_Request WHERE request_id = @request_id)
            THROW 50008, 'Request not found.', 1;

        INSERT INTO Payment (request_id, payment_type, amount, receipt_no, received_by)
        VALUES (@request_id, @payment_type, @amount, @receipt_no, @user_id);
        SET @payment_id = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

PRINT '04_procedures.sql completed: 9 procedures and 1 function created.';
GO
