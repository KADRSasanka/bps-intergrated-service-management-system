/* =====================================================================
   06_seed_data.sql  -  BPS_ServiceDB

   *** PLACEHOLDER DATA ***  Every line marked  -- REPLACE  must be replaced with
   the real value from the Badulla Pradeshiya Sabha before the final demo.
   Real (from the proposal): the list of items and machinery, the four user roles,
   the officer designations, the N.B.R.O rule for building/standard plan approvals.
   Placeholder: service names and target days, fees, charges, quantities, hall
   names and capacities, licence types, people.

   DEV LOGINS: every seeded user has the password   Password@123
   (bcrypt hash below). Change it before any real use.
   ===================================================================== */
USE BPS_ServiceDB;
GO

/* ---------- Users (dev password: Password@123) ---------- */
INSERT INTO User_Account (username, password_hash, role, designation)
SELECT v.username, v.password_hash, v.role, v.designation
FROM (VALUES
    ('admin1',      '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Admin',         'System Administrator'),   -- REPLACE
    ('clerk1',      '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Subject Clerk', 'Subject Clerk'),           -- REPLACE
    ('officer_ri',  '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Officer',       'Revenue Inspector'),      -- REPLACE
    ('officer_phi', '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Officer',       'Public Health Inspector'),-- REPLACE
    ('officer_to',  '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Officer',       'Technical Officer'),      -- REPLACE
    ('officer_ws',  '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Officer',       'Works Supervisor'),       -- REPLACE
    ('customer1',   '$2y$10$GOIP2ALXiJUdRjy8n0R2w.4FNMrNON6uzhdQr9sb2MY3qyAZNdFuy', 'Customer',      NULL)                      -- REPLACE (test account)
) AS v(username, password_hash, role, designation)
WHERE NOT EXISTS (SELECT 1 FROM User_Account u WHERE u.username = v.username);
GO

/* ---------- Customers (fake test people) ---------- */
INSERT INTO Customer (user_id, full_name, nic, contact_no, address)
SELECT (SELECT user_id FROM User_Account WHERE username = v.username), v.full_name, v.nic, v.contact_no, v.address
FROM (VALUES
    ('customer1', N'Test Customer One',   '199512345678', '0711111111', N'Badulla'),   -- REPLACE
    (NULL,        N'Test Customer Two',   '200145678912', '0722222222', N'Hali-Ela'),  -- REPLACE
    (NULL,        N'Test Customer Three', '857654321V',   '0733333333', N'Bandarawela')-- REPLACE
) AS v(username, full_name, nic, contact_no, address)
WHERE NOT EXISTS (SELECT 1 FROM Customer c WHERE c.nic = v.nic);
GO

/* ---------- Service catalog (BPS/1 to BPS/8) ----------
   REPLACE every name, target_days and fee with the Sabha's real values.
   Assumed mapping: 1-4 licences/certificates/approvals, 5 hall, 6-7 complaints, 8 rentals. */
INSERT INTO Service_Catalog (service_code, service_name, target_days, fee)
SELECT v.service_code, v.service_name, v.target_days, v.fee
FROM (VALUES
    ('BPS/1', N'Business and Trade Licence',     14, 500.00),   -- REPLACE
    ('BPS/2', N'Certificates',                    7, 100.00),   -- REPLACE
    ('BPS/3', N'Building Plan Approval',         21, 2000.00),  -- REPLACE
    ('BPS/4', N'Standard Plan Approval',         21, 1000.00),  -- REPLACE
    ('BPS/5', N'Hall Reservation',                3, 0.00),     -- REPLACE target days
    ('BPS/6', N'Environmental Complaint',         7, 0.00),     -- REPLACE
    ('BPS/7', N'Street Light Request',            7, 0.00),     -- REPLACE
    ('BPS/8', N'Item and Machinery Rental',       2, 0.00)      -- REPLACE target days
) AS v(service_code, service_name, target_days, fee)
WHERE NOT EXISTS (SELECT 1 FROM Service_Catalog s WHERE s.service_code = v.service_code);
GO

/* ---------- Licence types (requires_nbro = 1 for building and standard plan approvals, per the proposal) ---------- */
INSERT INTO Licence_Type (service_code, type_name, requires_nbro)
SELECT v.service_code, v.type_name, v.requires_nbro
FROM (VALUES
    ('BPS/1', N'Trade Licence',            0),   -- REPLACE
    ('BPS/1', N'Business Registration',    0),   -- REPLACE
    ('BPS/2', N'Residence Certificate',    0),   -- REPLACE
    ('BPS/2', N'Assessment Certificate',   0),   -- REPLACE
    ('BPS/3', N'Building Plan Approval',   1),   -- rule from proposal; REPLACE name if needed
    ('BPS/4', N'Standard Plan Approval',   1)    -- rule from proposal; REPLACE name if needed
) AS v(service_code, type_name, requires_nbro)
WHERE NOT EXISTS (SELECT 1 FROM Licence_Type l WHERE l.service_code = v.service_code AND l.type_name = v.type_name);
GO

/* ---------- Halls and sports ground ----------
   REPLACE names, capacities, charges and charge_basis (PerHour / PerDay / PerEvent).
   The sports ground is modelled as a hall because it is reserved by date and time. */
INSERT INTO Hall (name, capacity, rental_charge, charge_basis, description)
SELECT v.name, v.capacity, v.rental_charge, v.charge_basis, v.description
FROM (VALUES
    (N'Main Hall',     300,  15000.00, 'PerEvent', N'Placeholder description'),   -- REPLACE
    (N'Mini Hall',     100,   6000.00, 'PerEvent', N'Placeholder description'),   -- REPLACE
    (N'Sports Ground', 1500, 25000.00, 'PerDay',   N'Placeholder description')    -- REPLACE
) AS v(name, capacity, rental_charge, charge_basis, description)
WHERE NOT EXISTS (SELECT 1 FROM Hall h WHERE h.name = v.name);
GO

/* ---------- Rentable items and machinery ----------
   Names are from the proposal. REPLACE quantities, charges and charge_basis (PerDay / PerEvent). */
INSERT INTO Item (name, category, total_quantity, rental_charge, charge_basis)
SELECT v.name, v.category, v.total_quantity, v.rental_charge, v.charge_basis
FROM (VALUES
    (N'Plastic chair',                    'Furniture',  500,    10.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Plastic table',                    'Furniture',  100,    50.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Canopy (10 x 10 ft)',              'Equipment',   20,   500.00, 'PerEvent'),  -- REPLACE qty, charge
    (N'VIP stage',                        'Equipment',    1,  5000.00, 'PerEvent'),  -- REPLACE qty, charge
    (N'Iron flag pole',                   'Ceremony',    30,    50.00, 'PerEvent'),  -- REPLACE qty, charge
    (N'Flag',                             'Ceremony',    50,    20.00, 'PerEvent'),  -- REPLACE qty, charge
    (N'White flag',                       'Ceremony',    50,    20.00, 'PerEvent'),  -- REPLACE qty, charge
    (N'Water tank',                       'Equipment',   10,   300.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Water bowser',                     'Vehicle',      1,  4000.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Tractor and trailer',              'Vehicle',      2,  6000.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Backhoe machine',                  'Machinery',    1, 15000.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Tipper truck',                     'Vehicle',      2,  8000.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Concrete mixer',                   'Machinery',    2,  3000.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Grass and tree cutting machine',   'Machinery',    5,  1500.00, 'PerDay'),    -- REPLACE qty, charge
    (N'Festival and ceremony materials',  'Ceremony',    20,  1000.00, 'PerEvent')   -- REPLACE: list the real items
) AS v(name, category, total_quantity, rental_charge, charge_basis)
WHERE NOT EXISTS (SELECT 1 FROM Item i WHERE i.name = v.name);
GO

/* ---------- Check ---------- */
SELECT 'User_Account' AS tbl, COUNT(*) AS row_count FROM User_Account
UNION ALL SELECT 'Customer',        COUNT(*) FROM Customer
UNION ALL SELECT 'Service_Catalog', COUNT(*) FROM Service_Catalog
UNION ALL SELECT 'Licence_Type',    COUNT(*) FROM Licence_Type
UNION ALL SELECT 'Hall',            COUNT(*) FROM Hall
UNION ALL SELECT 'Item',            COUNT(*) FROM Item;
GO

PRINT '06_seed_data.sql completed. REMINDER: replace every line marked -- REPLACE with real Sabha data.';
GO
