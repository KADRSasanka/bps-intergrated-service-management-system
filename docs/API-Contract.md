# API Contract v1 — BPS Integrated Service Management System

Laravel REST API consumed by the hand-written Next.js API layer. The frontend depends on **this document**, never on tables or columns. A schema change is invisible to the frontend as long as this contract holds. Breaking changes go to `/api/v2`.

Status: **DRAFT v1**. Items marked `TBC` depend on answers from the Sabha.

---

## 1. Conventions

| Topic | Rule |
|---|---|
| Base URL | `http://localhost:8000/api/v1` |
| Format | JSON in and out. Headers `Accept: application/json`, `Content-Type: application/json` |
| Auth | Sanctum personal access token: `Authorization: Bearer <token>` |
| Keys | `snake_case` in JSON. The frontend mapper converts to camelCase |
| Ids | Integers. Service codes are strings like `"BPS/5"` (encode the slash in URLs: `BPS%2F5`) |
| Money | Number with 2 decimals, LKR (`1500.00`) |
| Dates | `date`: `2026-12-20` |
| Local datetimes | Reservation times: `2026-12-20T09:00:00`, Sri Lanka local time, **no offset** |
| UTC datetimes | System timestamps (`submitted_date`, `due_date`, `decided_at`, `paid_date`): `2026-12-20T03:30:00Z` |
| Lists | `GET` lists return `{ "data": [...], "meta": { "page": 1, "per_page": 25, "total": 120 } }`. Query: `?page=&per_page=` |
| Single item | `{ "data": { ... } }` |
| Created | `201` with the new object in `data` |
| No body | `204` for logout |

---

## 2. Error format

Every failure uses one envelope:

```json
{
  "message": "The hall is already booked for this period.",
  "code": "HALL_ALREADY_BOOKED",
  "errors": { "start_datetime": ["The hall is already booked for this period."] }
}
```

`errors` is present only for field-level validation (`422`). The UI shows `message` and, where possible, puts `errors[field]` next to the field.

### Database rule errors → HTTP

Laravel catches the SQL Server `THROW` number and maps it:

| SQL | `code` | HTTP | Meaning |
|---|---|---|---|
| 50001 | `HALL_ALREADY_BOOKED` | 409 | Overlapping Approved/Confirmed booking |
| 50002 | `CAPACITY_EXCEEDED` | 422 | Expected crowd above hall capacity |
| 50003 | `INSUFFICIENT_STOCK` | 409 | Not enough items for the period |
| 50004 | `ADVANCE_REQUIRED` | 422 | Confirm needs an advance payment |
| 50005 | `INVALID_STATUS` | 409 | Action not allowed in the current status |
| 50006 | `RETURN_EXCEEDS_ISSUED` | 422 | Returned + damaged more than issued |
| 50007 | `NBRO_REPORT_REQUIRED` | 422 | N.B.R.O report must be recorded first |
| 50008 | `NOT_FOUND` | 404 | Record missing or inactive |
| 50010 | `INVALID_DATE_RANGE` | 422 | End before start, due before issue |
| 50011 | `NOT_YOUR_STEP` | 403 | Officer not allowed for this step |
| 50012 | `INVALID_INPUT` | 422 | Other invalid input |
| 1205 | `TRY_AGAIN` | 409 | Deadlock victim; the client may retry once |

Other statuses: `401` not signed in, `403` wrong role, `404` unknown route or id, `422` validation, `500` anything unexpected (`code: "SERVER_ERROR"`, generic message, no SQL text).

---

## 3. Enumerations (fixed spelling, case-sensitive)

| Name | Values |
|---|---|
| `role` | `Admin`, `Subject Clerk`, `Officer`, `Customer` |
| `request_status` | `Pending`, `InProgress`, `Approved`, `Rejected`, `Completed`, `Cancelled` |
| `reservation_status` | `Pending`, `Approved`, `Confirmed`, `Cancelled` |
| `rental_status` | `Pending`, `Approved`, `Issued`, `Returned`, `Cancelled` |
| `approval_decision` | `Pending`, `Approved`, `Rejected` |
| `payment_type` | `Advance`, `Final`, `Fee`, `Compensation` |
| `charge_basis` (hall) | `PerHour`, `PerDay`, `PerEvent` |
| `charge_basis` (item) | `PerDay`, `PerEvent` |
| `item_category` | `Furniture`, `Equipment`, `Vehicle`, `Machinery`, `Ceremony`, `Other` |
| `complaint_category` | `Environment`, `StreetLight` |
| `received_by` | `Letter`, `Telephone`, `Online` |
| `damage_action` | `Replace`, `PayValue` |

`Overdue` is **not** a status. Overdue items come from the overdue report.

---

## 4. Roles and access

| Area | Customer | Officer | Subject Clerk | Admin |
|---|:-:|:-:|:-:|:-:|
| Register, sign in | ✔ | ✔ | ✔ | ✔ |
| Browse halls, items, services, availability | ✔ | | ✔ | ✔ |
| Create reservation / rental / service request | own | | for any customer | |
| See own requests | ✔ | | | |
| Approve, cancel reservations; issue, return items; record payments | | | ✔ | |
| Decide assigned requests | | ✔ | | |
| Reports | | over-target only | operational | all |
| Customers (create, edit) | | | ✔ | ✔ |
| Users, halls, items, services, charges | | | | ✔ |
| Audit log | | | | read |

NIC and phone numbers are masked for Customer-facing and Officer responses (`"XXXXXXXX1234"`). Clerk and Admin see real values.

---

## 5. Auth

### `POST /auth/register` (public, customers only)

```json
// request
{ "username": "nimal.p", "password": "Str0ng#Pass", "full_name": "Nimal Perera",
  "nic": "199512345678", "contact_no": "0711234567", "address": "Badulla" }
// 201
{ "data": { "customer_id": 12, "username": "nimal.p" } }
```
Errors: `422` username taken, NIC already registered (`"Please visit the Sabha office."`).

### `POST /auth/login` (public)

```json
// request
{ "username": "clerk1", "password": "Password@123" }
// 200
{ "data": {
    "token": "1|abc...",
    "user": { "user_id": 2, "username": "clerk1", "role": "Subject Clerk",
              "designation": "Subject Clerk", "customer_id": null }
} }
```
Wrong credentials: `401`, `code: "INVALID_CREDENTIALS"`.

### `GET /auth/me` → same `user` object · `POST /auth/logout` → `204`

---

## 6. Reference data (any signed-in user; read-only)

### `GET /halls`

```json
{ "data": [ { "hall_id": 1, "name": "Main Hall", "capacity": 300, "rental_charge": 15000.00,
              "charge_basis": "PerEvent", "description": "…", "photos": ["/photos/main-1.jpg"] } ] }
```

### `GET /halls/{hall_id}/availability?from=2026-12-01&to=2026-12-31`

Returns **booked** slots (Approved/Confirmed). Free time is everything else.

```json
{ "data": { "hall_id": 1, "booked": [
    { "start_datetime": "2026-12-20T09:00:00", "end_datetime": "2026-12-20T13:00:00" } ] } }
```

### `GET /items`

```json
{ "data": [ { "item_id": 1, "name": "Plastic chair", "category": "Furniture",
              "total_quantity": 500, "available_now": 460,
              "rental_charge": 10.00, "charge_basis": "PerDay" } ] }
```

### `GET /items/{item_id}/availability?from=2026-12-20&to=2026-12-22`

```json
{ "data": { "item_id": 1, "from": "2026-12-20", "to": "2026-12-22", "available": 350 } }
```

### `GET /services` and `GET /services/{service_code}/licence-types`

```json
{ "data": [ { "service_code": "BPS/3", "service_name": "Building Plan Approval",
              "target_days": 21, "fee": 2000.00 } ] }

{ "data": [ { "licence_type_id": 5, "type_name": "Building Plan Approval", "requires_nbro": true } ] }
```

---

## 7. Hall reservations

### `POST /reservations` (Customer, Clerk)

Customers: `customer_id` comes from the token and is ignored in the body. Clerks must send it.

```json
// request
{ "customer_id": 12, "hall_id": 1, "purpose": "Wedding reception", "expected_crowd": 250,
  "start_datetime": "2026-12-20T09:00:00", "end_datetime": "2026-12-20T13:00:00",
  "special_requirements": "Stage and sound" }
// 201: status Pending, holds nothing
{ "data": { "request_id": 87, "status": "Pending", "reservation_status": "Pending" } }
```

### `GET /reservations?date=2026-12-20&hall_id=&status=` (Clerk, Admin)

```json
{ "data": [ { "reservation_id": 87, "booking_date": "2026-12-20", "hall_id": 1, "hall_name": "Main Hall",
              "customer_id": 12, "customer_name": "Nimal Perera", "contact_no": "0711234567",
              "purpose": "Wedding reception", "expected_crowd": 250,
              "start_datetime": "2026-12-20T09:00:00", "end_datetime": "2026-12-20T13:00:00",
              "status": "Pending" } ], "meta": { "page": 1, "per_page": 25, "total": 1 } }
```

### `POST /reservations/{id}/approve` (Clerk)

Pending → Approved (blocks the hall). With `advance_amount` it also records the payment and sets Confirmed. Calling it on an Approved reservation requires `advance_amount`.

```json
// request
{ "advance_amount": 5000.00, "receipt_no": "R-2026-0412" }
// 200
{ "data": { "request_id": 87, "reservation_status": "Confirmed" } }
```
Errors: `HALL_ALREADY_BOOKED`, `ADVANCE_REQUIRED`, `INVALID_STATUS`.

### `POST /reservations/{id}/cancel` (Clerk) → `{ "data": { "request_id": 87, "reservation_status": "Cancelled" } }`

Customers cannot cancel; only the Subject Clerk can (per the Sabha).

---

## 8. Item rentals

### `POST /rentals` (Customer, Clerk)

```json
// request
{ "customer_id": 12, "purpose": "Funeral", "issue_date": "2026-12-20", "due_date": "2026-12-22",
  "lines": [ { "item_id": 1, "quantity": 50 }, { "item_id": 3, "quantity": 2 } ] }
// 201
{ "data": { "request_id": 90, "rental_status": "Pending" } }
```

### `GET /rentals?status=Issued` (Clerk, Admin)

```json
{ "data": [ { "rental_id": 90, "customer_name": "Nimal Perera", "contact_no": "0711234567",
              "issue_date": "2026-12-20", "due_date": "2026-12-22", "status": "Issued",
              "lines": [ { "item_id": 1, "item_name": "Plastic chair", "quantity_requested": 50,
                           "quantity_issued": 50, "quantity_returned": 0, "quantity_damaged": 0 } ] } ] }
```

### `POST /rentals/{id}/issue` (Clerk)

No body. Issues the full requested quantities (this is also the approval). Errors: `INSUFFICIENT_STOCK`, `INVALID_STATUS`.
```json
{ "data": { "request_id": 90, "rental_status": "Issued" } }
```

### `POST /rentals/{id}/return` (Clerk)

`returned` = units brought back. `damaged` = units lost or damaged **and not brought back**. A line closes when returned + damaged = issued; the rental becomes `Returned` when all lines close.

```json
// request
{ "lines": [ { "item_id": 1, "returned": 48, "damaged": 2, "action": "PayValue", "amount": 1500.00 } ] }
// 200
{ "data": { "request_id": 90, "rental_status": "Returned", "request_status": "Completed" } }
```
Errors: `RETURN_EXCEEDS_ISSUED`, `INVALID_INPUT` (damaged items need `action`; `PayValue` needs `amount`).

---

## 9. Service requests (licences, certificates, approvals, complaints, street lights)

### `POST /requests` (Customer, Clerk)

Service codes `BPS/1`–`BPS/4`, `BPS/6`, `BPS/7`. Halls and rentals use their own endpoints.

```json
// licence / certificate / approval
{ "service_code": "BPS/3", "customer_id": 12, "licence_type_id": 5,
  "assigned_officer_id": 7,
  "approval_steps": [ { "step": 1, "officer_id": 7 }, { "step": 2, "officer_id": 9 } ] }

// complaint / street light
{ "service_code": "BPS/7", "customer_id": 12, "category": "StreetLight",
  "location": "Main St, Badulla", "description": "Lamp not working", "received_by": "Online" }

// 201
{ "data": { "request_id": 95, "status": "Pending", "due_date": "2027-01-10T03:30:00Z" } }
```
`customer_id`, `assigned_officer_id`, `approval_steps` are Clerk-only. Approval order is `TBC` with the Sabha.

### `GET /requests?status=&service_code=&customer_id=` (Clerk, Admin)
### `GET /requests/{id}` (Clerk, Admin, assigned Officer)

```json
{ "data": {
    "request_id": 95, "service_code": "BPS/3", "service_name": "Building Plan Approval",
    "customer": { "customer_id": 12, "full_name": "Nimal Perera", "nic": "199512345678", "contact_no": "0711234567" },
    "status": "InProgress", "submitted_date": "2026-12-20T03:30:00Z", "due_date": "2027-01-10T03:30:00Z",
    "assigned_officer": { "user_id": 7, "username": "officer_to", "designation": "Technical Officer" },
    "licence": { "licence_type": "Building Plan Approval", "requires_nbro": true,
                 "nbro_report_no": null, "nbro_report_date": null },
    "complaint": null,
    "approvals": [ { "step": 1, "officer": "officer_to", "decision": "Pending", "decided_at": null, "remarks": null } ],
    "payments": [ { "payment_id": 3, "payment_type": "Fee", "amount": 2000.00, "paid_date": "2026-12-20T04:00:00Z", "receipt_no": "R-1" } ]
} }
```
Officers do not receive `payments`. Customer fields are masked for Officers.

### `POST /requests/{id}/decision` (Officer)

Records the signed-in officer's decision for the current step.

```json
// request
{ "decision": "Approved", "remarks": "Site checked",
  "nbro_report_no": "NBRO/2026/881", "nbro_report_date": "2026-12-15" }
// 200
{ "data": { "request_id": 95, "status": "Approved" } }
```
`nbro_*` fields are optional and only for licence types with `requires_nbro`. Errors: `NBRO_REPORT_REQUIRED`, `NOT_YOUR_STEP`, `INVALID_STATUS`.
Status result: any rejection → `Rejected`; more steps pending → `InProgress`; last step approved → `Approved` (licences) or `Completed` (complaints).

### `POST /requests/{id}/payments` (Clerk)

```json
// request: payment_type Final, Fee or Compensation (Advance is recorded by reservation approval)
{ "payment_type": "Fee", "amount": 2000.00, "receipt_no": "R-2026-0420" }
// 201
{ "data": { "payment_id": 14 } }
```

### `GET /my/requests` (Customer)

Own requests only, all services:

```json
{ "data": [ { "request_id": 87, "service_code": "BPS/5", "service_name": "Hall Reservation",
              "status": "Approved", "submitted_date": "2026-12-01T03:30:00Z", "due_date": "2026-12-04T03:30:00Z",
              "hall_name": "Main Hall", "start_datetime": "2026-12-20T09:00:00",
              "end_datetime": "2026-12-20T13:00:00", "reservation_status": "Confirmed" } ] }
```

### `GET /officer/requests?status=Pending` (Officer)

Lists requests where the signed-in officer holds the current pending step. Row fields are the same as `GET /requests`, without `payments`.

---

## 10. Customers and officers (Clerk, Admin)

| Endpoint | Notes |
|---|---|
| `GET /customers?search=` | Search by name or NIC |
| `POST /customers` | Walk-in registration: `full_name`, `nic`, `contact_no`, `address` |
| `GET /customers/{id}` · `PUT /customers/{id}` | |
| `GET /officers` | `[{ user_id, username, designation }]` for assigning requests |

---

## 11. Reports (read-only)

| Endpoint | Roles | Query | Row fields |
|---|---|---|---|
| `GET /reports/daily-bookings` | Clerk, Admin | `date` | as `GET /reservations` |
| `GET /reports/current-rentals` | Clerk, Admin | | `rental_id, customer_name, contact_no, item_name, quantity_issued, quantity_returned, quantity_damaged, quantity_outstanding, issue_date, due_date` |
| `GET /reports/overdue-items` | Clerk, Admin | | current-rentals fields + `days_overdue` |
| `GET /reports/item-stock` | Clerk, Admin | | `item_id, item_name, category, total_quantity, quantity_out_now, available_now` |
| `GET /reports/requests-over-target` | Clerk, Officer, Admin | | `request_id, service_code, service_name, customer_name, status, due_date, assigned_officer, days_over_target` |
| `GET /reports/service-performance` | Admin | | `service_code, service_name, target_days, total_requests, open_requests, decided_requests, cancelled_requests, avg_days_to_decide, decided_on_time, on_time_percent` |

`avg_days_to_decide` and `on_time_percent` are `null` for services without officer decisions (halls, rentals).

---

## 12. Admin

| Endpoint | Notes |
|---|---|
| `GET/POST /admin/users`, `PUT /admin/users/{id}` | `username, password (create only), role, designation, is_active`. Never returns `password_hash` |
| `GET/POST /admin/halls`, `PUT /admin/halls/{id}` | Includes `is_active`. Hall photos: `POST /admin/halls/{id}/photos` |
| `GET/POST /admin/items`, `PUT /admin/items/{id}` | Includes `is_active`, `total_quantity`, charges |
| `GET/POST /admin/services`, `PUT /admin/services/{code}` | `service_name, target_days, fee`; licence types under `/admin/services/{code}/licence-types` |
| `GET /admin/audit-logs?table=&record_id=&user_id=&from=&to=` | Read-only |

Nothing is deleted through the API. Use `is_active = false` or the `Cancelled` status.

Audit row:

```json
{ "log_id": 1042, "table_name": "Hall_Reservation", "record_id": "87", "action": "U", "user_id": 2,
  "old_value": { "status": "Pending" }, "new_value": { "status": "Approved" },
  "changed_at": "2026-12-20T04:10:00Z" }
```

---

## 13. Endpoint → database object (for the backend team)

| Endpoint | Database object |
|---|---|
| `POST /auth/register` | insert into `User_Account` + `Customer` (hardening: `sp_register_customer`) |
| `POST /reservations` | `sp_create_reservation` |
| `POST /reservations/{id}/approve` | `sp_approve_reservation` |
| `POST /reservations/{id}/cancel` | `sp_cancel_reservation` |
| `POST /rentals` | `sp_create_rental` |
| `POST /rentals/{id}/issue` | `sp_issue_items` |
| `POST /rentals/{id}/return` | `sp_return_items` |
| `POST /requests` | `sp_submit_request` |
| `POST /requests/{id}/decision` | `sp_advance_request` |
| `POST /requests/{id}/payments` | `sp_record_payment` |
| `GET /halls/{id}/availability` | `vw_hall_availability` |
| `GET /items`, `/reports/item-stock` | `vw_item_stock` |
| `GET /items/{id}/availability` | `fn_item_available` |
| `GET /my/requests` | `vw_my_requests` (set session `customer_id` first) |
| `GET /reports/daily-bookings` | `vw_daily_bookings` |
| `GET /reports/current-rentals` | `vw_current_rentals` |
| `GET /reports/overdue-items` | `vw_overdue_items` |
| `GET /reports/requests-over-target` | `vw_requests_over_target` |
| `GET /reports/service-performance` | `vw_service_performance` |
| `GET /officers` | `vw_officers` |

Rules for every database call:

1. Use the SQL connection for the signed-in role: `bps_customer`, `bps_clerk`, `bps_officer`, `bps_admin`. `bps_auth` is only for login, registration and tokens.
2. Run `EXEC sp_set_session_context 'user_id', <id>` on every request. Customers also set `'customer_id'`. Do this on every request because pooled connections are reused.
3. Return API Resources, never raw rows.

---

## 14. Open questions (`TBC`)

1. Approval order for each service (which officers, in what order).
2. Real service names, codes, target days and fees; hall and item charges and `charge_basis`.
3. Whether the Sabha wants a separate "approve rental" step before issuing.
4. Whether customers may upload documents with licence applications (not in v1).
