/* =====================================================================
   05_triggers.sql  -  BPS_ServiceDB

   Triggers:
     trg_prevent_hall_overlap     blocks overlapping hall bookings          (50001)
     trg_confirm_needs_advance    blocks Confirmed without advance payment  (50004)
     trg_check_item_stock         blocks issue quantity above stock         (50003)
     trg_set_request_due_date     sets due_date from Service_Catalog target_days
     trg_audit_hall_reservation \
     trg_audit_item_rental       |  write old/new values (JSON) to Audit_Log
     trg_audit_service_request   |  user_id comes from SESSION_CONTEXT('user_id'),
     trg_audit_payment          /   set by the stored procedures
   The procedures check the same rules first and return friendly errors.
   These triggers enforce them even if data is changed outside the application.
   A trigger that blocks a change rolls the whole transaction back.
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- 1. No overlapping Approved/Confirmed bookings for one hall ----------
   Rows of the same statement are already in the table, so overlaps inside one
   multi-row insert are caught too. UPDLOCK + HOLDLOCK stops two direct writers
   from both passing the check (one may be chosen as a deadlock victim). */
CREATE OR ALTER TRIGGER dbo.trg_prevent_hall_overlap
ON dbo.Hall_Reservation
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(status) OR UPDATE(hall_id) OR UPDATE(start_datetime) OR UPDATE(end_datetime)) RETURN;

    IF EXISTS (SELECT 1
               FROM inserted i
               JOIN dbo.Hall_Reservation h WITH (UPDLOCK, HOLDLOCK)
                 ON h.hall_id = i.hall_id
                AND h.request_id <> i.request_id
                AND h.status IN ('Approved','Confirmed')
                AND h.start_datetime < i.end_datetime
                AND h.end_datetime   > i.start_datetime
               WHERE i.status IN ('Approved','Confirmed'))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 50001, 'The hall is already booked for this period.', 1;
    END
END
GO

/* ---------- 2. Confirmed needs an advance payment ---------- */
CREATE OR ALTER TRIGGER dbo.trg_confirm_needs_advance
ON dbo.Hall_Reservation
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(status) RETURN;

    IF EXISTS (SELECT 1
               FROM inserted i
               WHERE i.status = 'Confirmed'
                 AND NOT EXISTS (SELECT 1 FROM dbo.Payment p
                                 WHERE p.request_id = i.request_id AND p.payment_type = 'Advance'))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 50004, 'Advance payment is required to confirm the reservation.', 1;
    END
END
GO

/* ---------- 3. Issued quantity cannot exceed available stock ----------
   Runs only when quantity_issued is inserted or changed (returns are ignored). */
CREATE OR ALTER TRIGGER dbo.trg_check_item_stock
ON dbo.Rental_Line
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(quantity_issued) RETURN;

    IF EXISTS (SELECT 1
               FROM inserted i
               JOIN dbo.Item_Rental ir ON ir.request_id = i.rental_id
               LEFT JOIN deleted d ON d.rental_id = i.rental_id AND d.item_id = i.item_id
               WHERE i.quantity_issued > 0
                 AND (d.rental_id IS NULL OR d.quantity_issued <> i.quantity_issued)
                 AND dbo.fn_item_available(i.item_id, ir.issue_date, ir.due_date, i.rental_id)
                     < i.quantity_issued)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 50003, 'Not enough stock for one or more items.', 1;
    END
END
GO

/* ---------- 4. Due date from the Service Catalog target time ----------
   Calendar days (weekends and holidays are not skipped). */
CREATE OR ALTER TRIGGER dbo.trg_set_request_due_date
ON dbo.Service_Request
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE sr
    SET sr.due_date = DATEADD(DAY, sc.target_days, sr.submitted_date)
    FROM dbo.Service_Request sr
    JOIN inserted i          ON i.request_id = sr.request_id
    JOIN dbo.Service_Catalog sc ON sc.service_code = sr.service_code
    WHERE sr.due_date IS NULL;
END
GO

/* ---------- 5. Audit triggers ---------- */
CREATE OR ALTER TRIGGER dbo.trg_audit_hall_reservation
ON dbo.Hall_Reservation
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = TRY_CAST(SESSION_CONTEXT(N'user_id') AS INT);

    INSERT INTO dbo.Audit_Log (table_name, record_id, action, user_id, old_value, new_value)
    SELECT 'Hall_Reservation',
           CAST(COALESCE(i.request_id, d.request_id) AS VARCHAR(60)),
           CASE WHEN d.request_id IS NULL THEN 'I' WHEN i.request_id IS NULL THEN 'D' ELSE 'U' END,
           @uid,
           (SELECT * FROM deleted  d2 WHERE d2.request_id = d.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT * FROM inserted i2 WHERE i2.request_id = i.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.request_id = i.request_id;
END
GO

CREATE OR ALTER TRIGGER dbo.trg_audit_item_rental
ON dbo.Item_Rental
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = TRY_CAST(SESSION_CONTEXT(N'user_id') AS INT);

    INSERT INTO dbo.Audit_Log (table_name, record_id, action, user_id, old_value, new_value)
    SELECT 'Item_Rental',
           CAST(COALESCE(i.request_id, d.request_id) AS VARCHAR(60)),
           CASE WHEN d.request_id IS NULL THEN 'I' WHEN i.request_id IS NULL THEN 'D' ELSE 'U' END,
           @uid,
           (SELECT * FROM deleted  d2 WHERE d2.request_id = d.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT * FROM inserted i2 WHERE i2.request_id = i.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.request_id = i.request_id;
END
GO

/* Service_Request: new_value is read from the table (not "inserted") so an INSERT
   shows the due_date set by trg_set_request_due_date (that trigger runs First, this one Last).
   The internal due_date update made by that trigger is not logged separately. */
CREATE OR ALTER TRIGGER dbo.trg_audit_service_request
ON dbo.Service_Request
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL(OBJECT_ID('dbo.trg_set_request_due_date'), 'AFTER', 'DML') > 0 RETURN;
    DECLARE @uid INT = TRY_CAST(SESSION_CONTEXT(N'user_id') AS INT);

    INSERT INTO dbo.Audit_Log (table_name, record_id, action, user_id, old_value, new_value)
    SELECT 'Service_Request',
           CAST(COALESCE(i.request_id, d.request_id) AS VARCHAR(60)),
           CASE WHEN d.request_id IS NULL THEN 'I' WHEN i.request_id IS NULL THEN 'D' ELSE 'U' END,
           @uid,
           (SELECT * FROM deleted d2 WHERE d2.request_id = d.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT * FROM dbo.Service_Request s2 WHERE s2.request_id = i.request_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.request_id = i.request_id;
END
GO

CREATE OR ALTER TRIGGER dbo.trg_audit_payment
ON dbo.Payment
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = TRY_CAST(SESSION_CONTEXT(N'user_id') AS INT);

    INSERT INTO dbo.Audit_Log (table_name, record_id, action, user_id, old_value, new_value)
    SELECT 'Payment',
           CAST(COALESCE(i.payment_id, d.payment_id) AS VARCHAR(60)),
           CASE WHEN d.payment_id IS NULL THEN 'I' WHEN i.payment_id IS NULL THEN 'D' ELSE 'U' END,
           @uid,
           (SELECT * FROM deleted  d2 WHERE d2.payment_id = d.payment_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT * FROM inserted i2 WHERE i2.payment_id = i.payment_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.payment_id = i.payment_id;
END
GO

/* ---------- Trigger order on Service_Request INSERT ----------
   CREATE OR ALTER resets the order, so it is set again here on every run. */
EXEC sp_settriggerorder @triggername = N'dbo.trg_set_request_due_date', @order = N'First', @stmttype = N'INSERT';
EXEC sp_settriggerorder @triggername = N'dbo.trg_audit_service_request', @order = N'Last',  @stmttype = N'INSERT';
GO

PRINT '05_triggers.sql completed: 8 triggers created.';
GO
