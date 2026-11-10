/* =====================================================================
   01_tables.sql  -  BPS_ServiceDB (Badulla Pradeshiya Sabha ISMS)
   Run after 00_create_db.sql.  Dev script: DROPS and recreates tables.
   Design notes:
   - Service_Request is the supertype; customer_id lives ONLY there.
   - Hall_Reservation, Item_Rental, Licence_Application, Complaint_Request
     use request_id as PK + FK to Service_Request (shared primary key).
   - Payment links to request_id, so it covers reservations, rentals and fees.
   - 'Overdue' is NOT stored. Derive it in vw_overdue_items.
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- Dev reset (child tables first) ---------- */
DROP TABLE IF EXISTS Audit_Log;
DROP TABLE IF EXISTS Request_Approval;
DROP TABLE IF EXISTS Complaint_Request;
DROP TABLE IF EXISTS Licence_Application;
DROP TABLE IF EXISTS Damage_Record;
DROP TABLE IF EXISTS Payment;
DROP TABLE IF EXISTS Rental_Line;
DROP TABLE IF EXISTS Item_Rental;
DROP TABLE IF EXISTS Hall_Reservation;
DROP TABLE IF EXISTS Service_Request;
DROP TABLE IF EXISTS Hall_Photo;
DROP TABLE IF EXISTS Item;
DROP TABLE IF EXISTS Hall;
DROP TABLE IF EXISTS Licence_Type;
DROP TABLE IF EXISTS Service_Catalog;
DROP TABLE IF EXISTS Customer;
DROP TABLE IF EXISTS User_Account;
GO

/* ---------- Users and customers ---------- */
CREATE TABLE User_Account (
    user_id        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    username       NVARCHAR(50)  NOT NULL UNIQUE,
    password_hash  NVARCHAR(255) NOT NULL,                -- bcrypt hash from Laravel
    role           VARCHAR(20)   NOT NULL CHECK (role IN ('Admin','Subject Clerk','Officer','Customer')),
    designation    NVARCHAR(80)  NULL,                    -- e.g. Revenue Inspector
    is_active      BIT           NOT NULL DEFAULT 1,
    created_at     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE Customer (
    customer_id  INT IDENTITY(1,1) PRIMARY KEY,
    user_id      INT           NULL REFERENCES User_Account(user_id),
    full_name    NVARCHAR(120) NOT NULL,
    nic          VARCHAR(12)   NOT NULL UNIQUE,
    contact_no   VARCHAR(15)   NOT NULL,
    address      NVARCHAR(250) NULL,
    created_at   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    -- old NIC: 9 digits + V/X; new NIC: 12 digits
    CONSTRAINT CK_Customer_nic CHECK (
        nic LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][VvXx]'
        OR nic LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
    ),
    CHECK (LEN(contact_no) >= 9)
);
GO
-- one customer profile per login (UNIQUE would allow only one NULL, so use a filtered index)
CREATE UNIQUE INDEX UX_Customer_user ON Customer(user_id) WHERE user_id IS NOT NULL;
GO

/* ---------- Service catalog ---------- */
CREATE TABLE Service_Catalog (
    service_code  VARCHAR(10)   PRIMARY KEY,
    service_name  NVARCHAR(100) NOT NULL UNIQUE,
    target_days   INT           NOT NULL CHECK (target_days > 0),
    fee           DECIMAL(10,2) NOT NULL DEFAULT 0
    CHECK (fee >= 0)
);
GO

CREATE TABLE Licence_Type (
    licence_type_id INT IDENTITY(1,1) PRIMARY KEY,
    service_code    VARCHAR(10)   NOT NULL REFERENCES Service_Catalog(service_code),
    type_name       NVARCHAR(100) NOT NULL,
    requires_nbro   BIT           NOT NULL DEFAULT 0,  -- N.B.R.O report needed first
    CONSTRAINT UQ_LicType UNIQUE (service_code, type_name)
);
GO

/* ---------- Halls and items ---------- */
CREATE TABLE Hall (
    hall_id        INT IDENTITY(1,1) PRIMARY KEY,
    name           NVARCHAR(100) NOT NULL UNIQUE,
    capacity       INT           NOT NULL CHECK (capacity > 0),
    rental_charge  DECIMAL(10,2) NOT NULL CHECK (rental_charge >= 0),
    charge_basis   VARCHAR(10)   NOT NULL DEFAULT 'PerEvent' CHECK (charge_basis IN ('PerHour','PerDay','PerEvent')),
    description    NVARCHAR(500) NULL,
    is_active      BIT           NOT NULL DEFAULT 1
);
GO

CREATE TABLE Hall_Photo (
    photo_id   INT IDENTITY(1,1) PRIMARY KEY,
    hall_id    INT           NOT NULL REFERENCES Hall(hall_id) ON DELETE CASCADE,
    file_path  NVARCHAR(260) NOT NULL
);
GO

CREATE TABLE Item (
    item_id        INT IDENTITY(1,1) PRIMARY KEY,
    name           NVARCHAR(100) NOT NULL UNIQUE,
    category       VARCHAR(20)   NOT NULL CHECK (category IN ('Furniture','Equipment','Vehicle','Machinery','Ceremony','Other')),
    total_quantity INT           NOT NULL CHECK (total_quantity >= 0),
    rental_charge  DECIMAL(10,2) NOT NULL CHECK (rental_charge >= 0),
    charge_basis   VARCHAR(10)   NOT NULL DEFAULT 'PerDay' CHECK (charge_basis IN ('PerDay','PerEvent')),
    is_active      BIT           NOT NULL DEFAULT 1
);
GO

/* ---------- Service_Request supertype ---------- */
CREATE TABLE Service_Request (
    request_id          INT IDENTITY(1,1) PRIMARY KEY,
    service_code        VARCHAR(10)  NOT NULL REFERENCES Service_Catalog(service_code),
    customer_id         INT          NOT NULL REFERENCES Customer(customer_id),
    submitted_date      DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    due_date            DATETIME2(0) NULL,                    -- set by trg_set_request_due_date
    status              VARCHAR(12)  NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending','InProgress','Approved','Rejected','Completed','Cancelled')),
    assigned_officer_id INT          NULL REFERENCES User_Account(user_id),
    created_by          INT          NULL REFERENCES User_Account(user_id)
);
GO

/* ---------- Hall reservation ---------- */
CREATE TABLE Hall_Reservation (
    request_id           INT PRIMARY KEY REFERENCES Service_Request(request_id),
    hall_id              INT           NOT NULL REFERENCES Hall(hall_id),
    purpose              NVARCHAR(200) NOT NULL,
    expected_crowd       INT           NOT NULL CHECK (expected_crowd > 0),
    start_datetime       DATETIME2(0)  NOT NULL,
    end_datetime         DATETIME2(0)  NOT NULL,
    special_requirements NVARCHAR(500) NULL,
    status               VARCHAR(10)   NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending','Approved','Confirmed','Cancelled')),
    CONSTRAINT CK_HallRes_period CHECK (end_datetime > start_datetime)
);
GO

/* ---------- Item rental ---------- */
CREATE TABLE Item_Rental (
    request_id  INT PRIMARY KEY REFERENCES Service_Request(request_id),
    purpose     NVARCHAR(200) NOT NULL,
    issue_date  DATE          NOT NULL,
    due_date    DATE          NOT NULL,
    status      VARCHAR(10)   NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending','Approved','Issued','Returned','Cancelled')),
    CHECK (due_date >= issue_date)
);
GO

CREATE TABLE Rental_Line (
    rental_id          INT NOT NULL REFERENCES Item_Rental(request_id),
    item_id            INT NOT NULL REFERENCES Item(item_id),
    quantity_requested INT NOT NULL CHECK (quantity_requested > 0),
    quantity_issued    INT NOT NULL DEFAULT 0,
    quantity_returned  INT NOT NULL DEFAULT 0,
    PRIMARY KEY (rental_id, item_id),
    CONSTRAINT CK_RentalLine_issued CHECK (quantity_issued >= 0 AND quantity_issued <= quantity_requested),
    CONSTRAINT CK_RentalLine_returned CHECK (quantity_returned >= 0 AND quantity_returned <= quantity_issued)
);
GO

/* ---------- Payments (reservations, rentals and licence fees) ---------- */
CREATE TABLE Payment (
    payment_id   INT IDENTITY(1,1) PRIMARY KEY,
    request_id   INT NOT NULL REFERENCES Service_Request(request_id),
    payment_type VARCHAR(12) NOT NULL CHECK (payment_type IN ('Advance','Final','Fee','Compensation')),
    amount       DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    paid_date    DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    receipt_no   VARCHAR(30)   NULL,
    received_by  INT           NULL REFERENCES User_Account(user_id)
);
GO

CREATE UNIQUE INDEX UX_Payment_receipt ON Payment(receipt_no) WHERE receipt_no IS NOT NULL;
GO

CREATE TABLE Damage_Record (
    record_id    INT IDENTITY(1,1) PRIMARY KEY,
    rental_id    INT NOT NULL,
    item_id      INT NOT NULL,
    quantity     INT NOT NULL CHECK (quantity > 0),
    action_taken VARCHAR(10) NOT NULL CHECK (action_taken IN ('Replace','PayValue')),
    amount       DECIMAL(10,2) NULL CHECK (amount IS NULL OR amount >= 0),
    recorded_at  DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    FOREIGN KEY (rental_id, item_id) REFERENCES Rental_Line(rental_id, item_id),
    -- paying the value requires an amount
    CHECK (action_taken <> 'PayValue' OR amount IS NOT NULL)
);
GO

/* ---------- Licences, certificates, approvals ---------- */
CREATE TABLE Licence_Application (
    request_id       INT PRIMARY KEY REFERENCES Service_Request(request_id),
    licence_type_id  INT NOT NULL REFERENCES Licence_Type(licence_type_id),
    nbro_report_no   VARCHAR(40) NULL,
    nbro_report_date DATE        NULL,
    -- report number and date go together; "required for this type" is enforced in sp_advance_request
    CHECK ((nbro_report_no IS NULL AND nbro_report_date IS NULL) OR (nbro_report_no IS NOT NULL AND nbro_report_date IS NOT NULL))
);
GO

/* ---------- Complaints and street lights ---------- */
CREATE TABLE Complaint_Request (
    request_id    INT PRIMARY KEY REFERENCES Service_Request(request_id),
    category      VARCHAR(12)   NOT NULL CHECK (category IN ('Environment','StreetLight')),
    location      NVARCHAR(250) NOT NULL,
    description   NVARCHAR(1000) NOT NULL,
    received_by   VARCHAR(10)   NOT NULL CHECK (received_by IN ('Letter','Telephone','Online')),
    resolved_date DATETIME2(0)  NULL
);
GO

/* ---------- Approval steps ---------- */
CREATE TABLE Request_Approval (
    approval_id INT IDENTITY(1,1) PRIMARY KEY,
    request_id  INT NOT NULL REFERENCES Service_Request(request_id),
    officer_id  INT NOT NULL REFERENCES User_Account(user_id),
    step_no     INT NOT NULL CHECK (step_no > 0),
    decision    VARCHAR(10) NOT NULL DEFAULT 'Pending' CHECK (decision IN ('Pending','Approved','Rejected')),
    decided_at  DATETIME2(0) NULL,
    remarks     NVARCHAR(500) NULL,
    CONSTRAINT UQ_Approval_step UNIQUE (request_id, step_no),
    CHECK ((decision = 'Pending' AND decided_at IS NULL) OR (decision <> 'Pending' AND decided_at IS NOT NULL))
);
GO

/* ---------- Audit log (filled by triggers) ---------- */
CREATE TABLE Audit_Log (
    log_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    table_name VARCHAR(60)  NOT NULL,
    record_id  VARCHAR(60)  NOT NULL,
    action     CHAR(1)      NOT NULL CHECK (action IN ('I','U','D')),
    user_id    INT          NULL,                           -- from SESSION_CONTEXT, set by the API
    old_value  NVARCHAR(MAX) NULL CHECK (old_value IS NULL OR ISJSON(old_value) = 1),
    new_value  NVARCHAR(MAX) NULL CHECK (new_value IS NULL OR ISJSON(new_value) = 1),
    changed_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

PRINT '01_tables.sql completed: 17 tables created.';
GO
