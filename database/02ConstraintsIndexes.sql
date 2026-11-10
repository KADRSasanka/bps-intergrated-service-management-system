/* =====================================================================
   Constraints (PK, FK, CHECK, UNIQUE, NOT NULL) are already in 01_tables.sql.
   This file adds the performance indexes from the proposal.
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- Hall availability ----------
   Filtered: only rows that block a hall (Approved / Confirmed).
   Procedures and triggers must use the SAME status list so the optimizer picks this index.
   Overlap test: start_datetime < @new_end AND end_datetime > @new_start */
CREATE INDEX IX_HallRes_active_period
    ON Hall_Reservation (hall_id, start_datetime, end_datetime)
    WHERE status IN ('Approved','Confirmed');
GO

/* ---------- Item availability ---------- */
CREATE INDEX IX_RentalLine_item
    ON Rental_Line (item_id)
    INCLUDE (rental_id, quantity_issued, quantity_returned);
GO

CREATE INDEX IX_ItemRental_dates
    ON Item_Rental (issue_date, due_date)
    INCLUDE (status);
GO

/* ---------- Request tracking and overdue requests ---------- */
CREATE INDEX IX_Request_status_due
    ON Service_Request (status, due_date)
    INCLUDE (service_code);
GO

CREATE INDEX IX_Request_customer
    ON Service_Request (customer_id);
GO

CREATE INDEX IX_Request_officer
    ON Service_Request (assigned_officer_id, status);
GO

/* ---------- Supporting lookups ---------- */
CREATE INDEX IX_Payment_request
    ON Payment (request_id);
GO

CREATE INDEX IX_Approval_officer
    ON Request_Approval (officer_id, decision);
GO

CREATE INDEX IX_Audit_record
    ON Audit_Log (table_name, record_id);
GO

PRINT '02_constraints_indexes.sql completed: 9 indexes created.';
GO
