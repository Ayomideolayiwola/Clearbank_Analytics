# ClearBank — Analytics Engineering
## Phase 0: Dimensional Model Design

> ⚠️ **Mandatory design deliverable.** This document must be reviewed and signed off before any dbt models are built.

---

## Table of Contents

1. [Overview](#overview)
2. [Business Processes & Fact Tables](#business-processes--fact-tables)
   - [Fact 1: Transactions](#business-process-1-money-moving-through-accounts)
   - [Fact 2: Loan Repayments](#business-process-2-loan-repayment-activity)
3. [Raw Source Tables](#raw-source-tables)
4. [Dimensional Model Design](#dimensional-model-design)
   - [Fact Tables](#fact-tables)
   - [Dimension Tables](#dimension-tables)
5. [Star Schema Diagrams](#star-schema-diagrams)
6. [Design Decisions & Assumptions](#design-decisions--assumptions)

---

## Overview

ClearBank is a mid-sized digital retail bank offering current accounts, savings accounts, loans, and debit cards to individual customers. The analytics engineering layer governs, tests, and documents the transformation of raw transactional data into a reliable, production-ready dimensional model.

The raw data lives in a schema called `raw` in a cloud data warehouse (Snowflake). The analytics team has been querying these raw tables directly for months. This document defines the dimensional model that replaces ad-hoc SQL with a governed, tested, and reusable analytics layer.

---

## Business Processes & Fact Tables

This section identifies the key **measurable business events** at ClearBank and defines a fact table for each. The grain of each fact table is stated explicitly before any SQL is written.

---

### Business Process 1: Money moving through accounts

| | |
|---|---|
| **Event measured** | A debit or credit movement on a ClearBank customer account |
| **Examples** | Card purchase, ATM withdrawal, bank transfer in/out, direct debit, standing order, fee charge |
| **Fact table** | `fact_transactions` |

#### Grain

> **One row = one transaction event posted against a ClearBank account, on a specific date, via a specific channel, in a specific direction (debit or credit).**

Each row represents a single, atomic movement of money. A customer who makes five purchases in one day produces five rows. Pending and failed transactions are excluded — only `settled` transactions are loaded.

#### Measures

| Measure | Additivity | Notes |
|---|---|---|
| `transaction_amount` | Fully additive | Stored in the transaction currency |
| `balance_after` | Semi-additive | Account balance snapshot after this event. Sum across accounts is meaningless — use `LAST_VALUE()` per account |
| `transaction_count` | Fully additive | Always `1` per row; used for volume aggregations |

---

### Business Process 2: Loan repayment activity

| | |
|---|---|
| **Event measured** | A scheduled or actual repayment event against a ClearBank loan |
| **Examples** | Monthly direct debit repayment, manual overpayment, missed payment, partial payment, late fee charged |
| **Fact table** | `fact_loan_repayments` |

#### Grain

> **One row = one repayment event (scheduled or actual) against a specific loan, on a specific scheduled repayment date, recording what was due, what was paid, and how late the payment was.**

Each loan with a 12-month term will produce up to 12 rows — one per scheduled repayment cycle — plus additional rows for any ad-hoc overpayments or failed payment retries.

#### Measures

| Measure | Additivity | Notes |
|---|---|---|
| `amount_due` | Fully additive | What the customer was scheduled to pay |
| `amount_paid` | Fully additive | What was actually received |
| `principal_component` | Fully additive | Portion of payment reducing the loan balance |
| `interest_component` | Fully additive | Portion of payment servicing interest |
| `late_fee` | Fully additive | Fee charged for late payment; `0` if on time |
| `days_late` | **Non-additive** | ⚠️ Snapshot metric. Use `MAX()` for worst delinquency or `AVG()` for portfolio health. **Never `SUM()`** |
| `repayment_count` | Fully additive | Always `1` per row |

---

## Raw Source Tables

The following six tables exist in the `raw` schema. Column definitions are taken directly from the source system.

---

### `raw.customers`
One row per customer. Updated on CRM change events.

| Column | Type | Notes |
|---|---|---|
| `customer_id` | `varchar` | Natural PK |
| `first_name` | `varchar` | |
| `middle_name` | `varchar` | Nullable |
| `last_name` | `varchar` | |
| `date_of_birth` | `date` | |
| `email` | `varchar` | PII — hashed in staging |
| `phone_number_1` | `varchar` | PII — hashed in staging |
| `phone_number_2` | `varchar` | PII — hashed in staging, nullable |
| `address_line_1` | `varchar` | PII |
| `address_line_2` | `varchar` | PII, nullable |
| `city` | `varchar` | |
| `country` | `varchar` | ISO 3166-1 alpha-2 |
| `kyc_status` | `varchar` | `verified` / `pending` / `failed` |
| `customer_segment` | `varchar` | `retail` / `premium` / `student` |
| `acquisition_channel` | `varchar` | `organic` / `referral` / `paid_social` / `branch` |
| `referral_code_used` | `varchar` | Nullable; populated when `acquisition_channel = 'referral'` |
| `is_active` | `boolean` | |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | Used for SCD Type 2 change detection |

---

### `raw.accounts`
One row per bank account.

| Column | Type | Notes |
|---|---|---|
| `account_id` | `varchar` | Natural PK |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `account_type` | `varchar` | `current` / `savings` / `isa` |
| `account_number` | `varchar` | 8-digit UK account number |
| `sort_code` | `varchar` | 6-digit UK sort code |
| `iban` | `varchar` | International Bank Account Number |
| `currency` | `varchar` | ISO 4217 (e.g. `GBP`) |
| `account_status` | `varchar` | `active` / `dormant` / `closed` / `suspended` |
| `current_balance` | `decimal` | Current ledger balance |
| `available_balance` | `decimal` | Balance available for spending (excludes pending holds) |
| `interest_rate` | `decimal` | Annual interest rate (e.g. `0.035` for 3.5%) |
| `opened_date` | `date` | |
| `closed_date` | `date` | Nullable; populated when account is closed |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | |

---

### `raw.transactions`
One row per transaction event. Highest-volume table.

| Column | Type | Notes |
|---|---|---|
| `transaction_id` | `varchar` | Natural PK |
| `account_id` | `varchar` | FK → `raw.accounts` |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `transaction_date` | `date` | Calendar date of the transaction |
| `transaction_type` | `varchar` | `purchase` / `transfer` / `atm_withdrawal` / `direct_debit` / `standing_order` / `fee` / `interest` |
| `counterpart_name` | `varchar` | Nullable; name of the other party |
| `counterpart_acc_no` | `varchar` | Nullable; other party's account number |
| `counterpart_sort_code` | `varchar` | Nullable; other party's sort code |
| `direction` | `varchar` | `debit` / `credit` |
| `transaction_amount` | `decimal` | Absolute value; direction determined by `direction` column |
| `currency` | `varchar` | ISO 4217 |
| `balance_after` | `decimal` | Account balance after this transaction |
| `status` | `varchar` | `settled` / `pending` / `failed` / `reversed` |
| `channel` | `varchar` | `mobile_app` / `web` / `atm` / `branch` / `api` / `pos` |
| `reference` | `varchar` | Free-text payment reference |
| `initiated_at` | `timestamp` | When the transaction was initiated |
| `settled_at` | `timestamp` | Nullable; when the transaction was settled |
| `created_at` | `timestamp` | |

---

### `raw.loans`
One row per loan agreement.

| Column | Type | Notes |
|---|---|---|
| `loan_id` | `varchar` | Natural PK |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `account_id` | `varchar` | FK → `raw.accounts` — the disbursement account |
| `loan_type` | `varchar` | `personal` / `auto` / `mortgage` / `overdraft` |
| `applied_amount` | `decimal` | Amount the customer applied for |
| `approved_amount` | `decimal` | Amount approved (may differ from applied) |
| `disbursed_amount` | `decimal` | Amount actually paid out |
| `upfront_fee` | `decimal` | Origination/arrangement fee |
| `currency` | `varchar` | ISO 4217 |
| `interest_rate` | `decimal` | Annual interest rate |
| `tenure_months` | `integer` | Loan term in months |
| `total_repayable` | `decimal` | Total amount due over the life of the loan |
| `loan_status` | `varchar` | `active` / `settled` / `defaulted` / `written_off` / `pending_approval` |
| `application_date` | `date` | |
| `approval_date` | `date` | Nullable |
| `disbursement_date` | `date` | Nullable; when funds were released |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | |

---

### `raw.loan_repayments`
One row per repayment event against a loan.

| Column | Type | Notes |
|---|---|---|
| `repayment_id` | `varchar` | Natural PK |
| `loan_id` | `varchar` | FK → `raw.loans` |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `account_id` | `varchar` | FK → `raw.accounts` — account debited |
| `scheduled_repayment_date` | `date` | The date repayment was due |
| `actual_payment_date` | `date` | Nullable; date payment was received |
| `amount_due` | `decimal` | Amount scheduled to be paid |
| `amount_paid` | `decimal` | Amount actually received |
| `principal_component` | `decimal` | Portion reducing the loan balance |
| `interest_component` | `decimal` | Portion servicing interest |
| `late_fee` | `decimal` | `0` if on time |
| `days_late` | `integer` | `0` if on time — ⚠️ non-additive |
| `payment_method` | `varchar` | `direct_debit` / `manual_transfer` / `card` |
| `repayment_status` | `varchar` | `completed` / `failed` / `partial` / `reversed` |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | |

---

### `raw.cards`
One row per card issued to a customer.

| Column | Type | Notes |
|---|---|---|
| `card_id` | `varchar` | Natural PK |
| `account_id` | `varchar` | FK → `raw.accounts` |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `card_type` | `varchar` | `debit` / `virtual` / `prepaid` |
| `card_network` | `varchar` | `visa` / `mastercard` |
| `card_status` | `varchar` | `active` / `blocked` / `cancelled` / `expired` |
| `is_contactless_enabled` | `boolean` | |
| `is_online_enabled` | `boolean` | |
| `is_international_enabled` | `boolean` | |
| `daily_withdrawal_limit` | `decimal` | ATM withdrawal limit |
| `issued_date` | `date` | |
| `activation_date` | `date` | Nullable; populated when customer activates card |
| `expires_at` | `date` | |
| `cancelled_at` | `timestamp` | Nullable |
| `created_at` | `timestamp` | |
| `updated_at` | `timestamp` | |

---

## Dimensional Model Design

### Fact Tables

#### `fact_transactions`

| Column | Type | Description |
|---|---|---|
| `transaction_key` | `integer` | Surrogate PK |
| `transaction_id` | `varchar` | Natural key (kept for audit) |
| `account_key` | `integer` | FK → `dim_account` |
| `customer_key` | `integer` | FK → `dim_customer` |
| `date_key` | `integer` | FK → `dim_date` (YYYYMMDD) |
| `channel_key` | `integer` | FK → `dim_channel` |
| `transaction_type_key` | `integer` | FK → `dim_transaction_type` |
| `counterpart_name` | `varchar` | Degenerate dimension |
| `reference` | `varchar` | Degenerate dimension |
| `direction` | `varchar` | `debit` / `credit` |
| `transaction_amount` | `decimal` | Measure — fully additive |
| `balance_after` | `decimal` | Measure — semi-additive |
| `transaction_count` | `integer` | Always `1` — for volume aggregations |
| `initiated_at` | `timestamp` | |
| `settled_at` | `timestamp` | |

---

#### `fact_loan_repayments`

| Column | Type | Description |
|---|---|---|
| `repayment_key` | `integer` | Surrogate PK |
| `repayment_id` | `varchar` | Natural key (kept for audit) |
| `loan_key` | `integer` | FK → `dim_loan` |
| `customer_key` | `integer` | FK → `dim_customer` ✦ conformed |
| `account_key` | `integer` | FK → `dim_account` |
| `date_key` | `integer` | FK → `dim_date` (scheduled date) ✦ conformed |
| `payment_method` | `varchar` | Degenerate dimension |
| `repayment_status` | `varchar` | Degenerate dimension |
| `amount_due` | `decimal` | Measure — fully additive |
| `amount_paid` | `decimal` | Measure — fully additive |
| `principal_component` | `decimal` | Measure — fully additive |
| `interest_component` | `decimal` | Measure — fully additive |
| `late_fee` | `decimal` | Measure — fully additive |
| `days_late` | `integer` | Measure — ⚠️ **non-additive** |
| `delinquency_bucket` | `varchar` | Derived: `Current` / `1–30 days` / `31–60 days` / `60+ days` |
| `is_late` | `boolean` | Derived: `days_late > 0` |
| `repayment_count` | `integer` | Always `1` |

---

### Dimension Tables

#### `dim_customer` — SCD Type 2

Tracks changes to `kyc_status`, `customer_segment`, `city`, and `is_active` over time. Historical accuracy is required so that transactions are attributed to the correct customer profile at the time they occurred.

| Column | Type | Notes |
|---|---|---|
| `customer_key` | `integer` | Surrogate PK |
| `customer_id` | `varchar` | Natural key |
| `first_name` | `varchar` | |
| `last_name` | `varchar` | |
| `full_name` | `varchar` | Derived |
| `date_of_birth` | `date` | |
| `age_band` | `varchar` | Derived: `18–24` / `25–34` / `35–44` etc. |
| `city` | `varchar` | |
| `country` | `varchar` | |
| `kyc_status` | `varchar` | |
| `customer_segment` | `varchar` | |
| `acquisition_channel` | `varchar` | |
| `is_active` | `boolean` | |
| `valid_from` | `date` | SCD Type 2 |
| `valid_to` | `date` | `9999-12-31` if current record |
| `is_current` | `boolean` | |

> ⚠️ **PII policy:** `email`, `phone_number_1`, `phone_number_2`, `address_line_1`, `address_line_2` are present in `raw.customers` but are **excluded from `dim_customer`**. They are hashed in the staging layer (`stg_customers`) and never propagated into the analytics schema.

---

#### `dim_account` — SCD Type 2

Tracks changes to `account_status` and `interest_rate` over time.

| Column | Type | Notes |
|---|---|---|
| `account_key` | `integer` | Surrogate PK |
| `account_id` | `varchar` | Natural key |
| `customer_id` | `varchar` | FK reference (natural key) |
| `account_type` | `varchar` | `current` / `savings` / `isa` |
| `currency` | `varchar` | |
| `account_status` | `varchar` | |
| `interest_rate` | `decimal` | |
| `opened_date` | `date` | |
| `closed_date` | `date` | |
| `is_active` | `boolean` | Derived |
| `valid_from` | `date` | |
| `valid_to` | `date` | |
| `is_current` | `boolean` | |

---

#### `dim_loan` — Type 1

Loan terms are fixed at origination — Type 1 is correct. No history needs to be preserved.

| Column | Type | Notes |
|---|---|---|
| `loan_key` | `integer` | Surrogate PK |
| `loan_id` | `varchar` | Natural key |
| `customer_id` | `varchar` | FK reference |
| `loan_type` | `varchar` | |
| `approved_amount` | `decimal` | |
| `disbursed_amount` | `decimal` | |
| `interest_rate` | `decimal` | |
| `tenure_months` | `integer` | |
| `total_repayable` | `decimal` | |
| `loan_status` | `varchar` | |
| `disbursement_date` | `date` | |
| `loan_size_band` | `varchar` | Derived: `Under £1k` / `£1k–£5k` etc. |
| `rate_band` | `varchar` | Derived: `Under 5%` / `5–10%` etc. |

---

#### `dim_date` — Static, Conformed ✦

Pre-populated spine from `2015-01-01` to `2030-12-31`. Not sourced from any raw table — generated via `dbt_utils.date_spine`. Shared by both fact tables, making it the primary **conformed dimension** in the model.

| Column | Type | Notes |
|---|---|---|
| `date_key` | `integer` | Surrogate PK — YYYYMMDD format |
| `full_date` | `date` | |
| `day_of_week_name` | `varchar` | `Monday` etc. |
| `day_of_week_num` | `integer` | 1 (Mon) to 7 (Sun) |
| `month_num` | `integer` | 1–12 |
| `month_name` | `varchar` | |
| `calendar_quarter` | `integer` | 1–4 |
| `calendar_year` | `integer` | |
| `fiscal_year` | `integer` | ClearBank fiscal year — April start |
| `fiscal_quarter` | `integer` | Relative to April |
| `is_weekend` | `boolean` | |
| `is_uk_bank_holiday` | `boolean` | |
| `month_start_date` | `date` | |
| `month_end_date` | `date` | |

---

#### `dim_channel` — Type 1

| Column | Type | Notes |
|---|---|---|
| `channel_key` | `integer` | Surrogate PK |
| `channel_name` | `varchar` | `mobile_app` / `web` / `atm` / `branch` / `api` / `pos` |
| `channel_type` | `varchar` | `digital` / `physical` |
| `is_digital` | `boolean` | Derived |

---

#### `dim_transaction_type` — Type 1

Adds `category` and `direction` to avoid raw string matching in every downstream query.

| Column | Type | Notes |
|---|---|---|
| `transaction_type_key` | `integer` | Surrogate PK |
| `type_name` | `varchar` | Raw value from source |
| `type_label` | `varchar` | Display label |
| `category` | `varchar` | `payment` / `transfer` / `cash` / `fee` / `interest` |
| `direction` | `varchar` | `debit` / `credit` |

---

#### `dim_card` — Type 2

Card attributes like `card_status`, `is_contactless_enabled`, and limits can change. SCD Type 2 preserves the card state at the time of any transaction.

| Column | Type | Notes |
|---|---|---|
| `card_key` | `integer` | Surrogate PK |
| `card_id` | `varchar` | Natural key |
| `account_id` | `varchar` | FK reference |
| `customer_id` | `varchar` | FK reference |
| `card_type` | `varchar` | |
| `card_network` | `varchar` | |
| `card_status` | `varchar` | |
| `is_contactless_enabled` | `boolean` | |
| `is_online_enabled` | `boolean` | |
| `is_international_enabled` | `boolean` | |
| `daily_withdrawal_limit` | `decimal` | |
| `issued_date` | `date` | |
| `expires_at` | `date` | |
| `valid_from` | `date` | |
| `valid_to` | `date` | |
| `is_current` | `boolean` | |

---

## Star Schema Diagrams

### Schema 1 — `fact_transactions`

```
         ┌──────────────────┐        ┌─────────────────────┐
         │   dim_customer   │        │     dim_account      │
         │  ✦ conformed     │        │    (SCD Type 2)      │
         └────────┬─────────┘        └──────────┬──────────┘
                  │ customer_key                 │ account_key
                  │       ┌─────────────────────┘
         ┌────────▼───────▼──────────────────────────┐
         │              fact_transactions             │
         │  transaction_key    (PK)                   │
         │  account_key        (FK) ──► dim_account   │
         │  customer_key       (FK) ──► dim_customer  │
         │  date_key           (FK) ──► dim_date      │
         │  channel_key        (FK) ──► dim_channel   │
         │  transaction_type_key(FK)──► dim_txn_type  │
         │  ─────────────────────────────────────     │
         │  transaction_amount   [additive]           │
         │  balance_after        [semi-additive]      │
         │  transaction_count    [additive]           │
         └──────────────────┬────────────────────────┘
                            │ date_key
               ┌────────────▼────────────┐
               │        dim_date         │
               │      ✦ conformed        │
               └─────────────────────────┘
```

---

### Schema 2 — `fact_loan_repayments`

```
   ┌───────────────┐                        ┌──────────────────┐
   │   dim_loan    │                        │   dim_customer   │
   │   (Type 1)    │                        │   ✦ conformed    │
   └───────┬───────┘                        └────────┬─────────┘
           │ loan_key                    customer_key │
           │        ┌────────────────────────────────┘
  ┌────────▼────────▼─────────────────────────────────┐
  │                fact_loan_repayments                │
  │  repayment_key      (PK)                          │
  │  loan_key           (FK) ──► dim_loan             │
  │  customer_key       (FK) ──► dim_customer         │
  │  account_key        (FK) ──► dim_account          │
  │  date_key           (FK) ──► dim_date             │
  │  ─────────────────────────────────────────────    │
  │  amount_due           [additive]                  │
  │  amount_paid          [additive]                  │
  │  principal_component  [additive]                  │
  │  interest_component   [additive]                  │
  │  late_fee             [additive]                  │
  │  days_late            [⚠️ NON-ADDITIVE]           │
  │  repayment_count      [additive]                  │
  └──────────────────┬────────────────────────────────┘
                     │ date_key
        ┌────────────▼────────────┐
        │        dim_date         │
        │      ✦ conformed        │
        └─────────────────────────┘
```

---

### Conformed Dimensions

| Dimension | Used by | Why conformed |
|---|---|---|
| `dim_date` | `fact_transactions` + `fact_loan_repayments` | Consistent time axis across all business processes |
| `dim_customer` | `fact_transactions` + `fact_loan_repayments` | Enables cross-process queries e.g. "customers in arrears — what is their spending pattern?" |
| `dim_account` | `fact_transactions` + `fact_loan_repayments` | The same account can have transactions and a loan attached |

---

## Design Decisions & Assumptions

### Amounts kept as decimals (not pence integers)

The source columns (`transaction_amount`, `amount_due`, `amount_paid` etc.) are defined as `decimal` in the raw tables. They are preserved as decimals throughout the model. If float precision becomes an issue in production, a migration to integer pence storage can be applied at the staging layer without touching the fact tables.

### Surrogate keys on all dimensions

Natural keys (`customer_id`, `account_id` etc.) are preserved as attributes but **integer surrogate keys drive all joins**. This is required for SCD Type 2 — a single `customer_id` will have multiple surrogate keys, one per historical version — and insulates the warehouse from upstream key changes.

### `dim_date` uses `YYYYMMDD` integer as key

`date_key` is an integer in `YYYYMMDD` format (e.g. `20240315`) rather than a `DATE` type foreign key. This is human-readable when browsing fact data, performs well on all major warehouses, and is the established convention for dimensional modelling.

### `fact_transactions` filters to `status = 'settled'` only

Only settled transactions are loaded into `fact_transactions`. Pending transactions are excluded to avoid double-counting. Reversed transactions produce an offsetting row with a negative amount, preserving the audit trail while keeping aggregate sums correct. Failed transactions are excluded entirely.

### `days_late` is explicitly documented as non-additive

Every model YAML file and this document flags `days_late` as non-additive. Correct aggregations:

| Use case | Correct SQL |
|---|---|
| Worst delinquency in a period | `MAX(days_late)` |
| Average days late across portfolio | `AVG(days_late)` |
| Count of late repayments | `COUNT_IF(days_late > 0)` |
| ❌ Total days late (meaningless) | ~~`SUM(days_late)`~~ |

### SCD Type 2 on `dim_customer`, `dim_account`, `dim_card`

Type 2 is applied to dimensions where **historical accuracy matters for regulatory reporting**. A transaction from 2022 must be attributed to the customer's segment as it was in 2022. The `is_current = true` filter retrieves present-day attributes for operational dashboards.

### PII is hashed in staging, not surfaced in dimensions

`email`, `phone_number_1`, `phone_number_2`, `address_line_1`, and `address_line_2` from `raw.customers` are one-way hashed (SHA-256) in `stg_customers` and excluded from `dim_customer`. This ensures the analytics layer complies with ClearBank's data minimisation obligations under UK GDPR. The hashes are available in staging for identity resolution use cases that have been explicitly approved.

### `dim_card` is included as a dimension

The `raw.cards` table contains several boolean flags (`is_contactless_enabled`, `is_online_enabled`, `is_international_enabled`) that are meaningful analytical attributes — for example, "what proportion of fraud transactions came from cards with international payments enabled?" Modelling cards as a dimension enables this slice without joining to the raw table in every query.

### `applied_amount` vs `approved_amount` vs `disbursed_amount`

The `raw.loans` table records all three stages. `dim_loan` carries all three so analysts can measure approval rates (`approved_amount / applied_amount`) and utilisation (`disbursed_amount / approved_amount`) without going back to raw.

---

*Document status: **Final — ready for dbt build***
*Next phase: Phase 1 — dbt project structure, staging models, and source freshness tests*
