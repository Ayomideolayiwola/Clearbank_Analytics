
# ClearBank — Analytics Engineering
## Phase 0: Dimensional Model Design


---

## Table of Contents

1. [Overview](#overview)
2. [Business Processes & Fact Tables](#business-processes--fact-tables)
   - [Fact 1: Transactions](#business-process-1-money-moving-through-accounts)
   - [Fact 2: Loan Repayments](#business-process-2-loan-repayment-activity)
3. [Raw Source Table Assumptions](#raw-source-table-assumptions)
4. [Dimension Table Designs](#dimension-table-designs)
5. [Star Schema Diagrams](#star-schema-diagrams)
6. [Design Decisions & Key Assumptions](#design-decisions--key-assumptions)

---

## Overview

ClearBank is a mid-sized digital retail bank offering current accounts, savings accounts, loans, and debit cards to individual customers. The analytics engineering layer is being built on top of raw transactional data that has been migrated into a cloud data warehouse (Snowflake).

This document defines the dimensional model — the governed, tested, and documented layer that sits between raw source tables and the BI/reporting layer.

---

## Business Processes & Fact Tables

### Business Process 1: Money moving through accounts

| Property | Detail |
|---|---|
| **Event measured** | A debit or credit transaction posted to a customer account |
| **Examples** | Card purchases, ATM withdrawals, direct debits, incoming transfers, interest credits, fee charges |
| **Fact table** | `fact_transactions` |

#### Grain

> **One row = one individual debit or credit event posted to a ClearBank account, on a specific calendar date, initiated via a specific channel.**

The grain is at the individual transaction level. A single day of activity for a single account will produce multiple rows — one per posted transaction event.

#### Measures

| Measure | Additivity | Notes |
|---|---|---|
| `transaction_amount` | Fully additive | Stored in pence (integer). Negative = debit, positive = credit |
| `running_balance` | Semi-additive | Balance after this event. Sum across accounts is meaningless; use `LAST_VALUE()` per account |
| `fee_amount` | Fully additive | £0 (i.e. 0 pence) if no fee applies to this transaction |
| `transaction_count` | Fully additive | Always `1` per row; summed in aggregations for volume metrics |

---

### Business Process 2: Loan repayment activity

| Property | Detail |
|---|---|
| **Event measured** | A payment event applied against a ClearBank loan |
| **Examples** | Scheduled monthly repayment, ad-hoc overpayment, missed/partial payment, failed direct debit |
| **Fact table** | `fact_loan_repayments` |

#### Grain

> **One row = one repayment event (scheduled or ad-hoc) against a specific ClearBank loan, recorded on a specific date, with the payment decomposed into its principal and interest components.**

A loan with 36 monthly repayments will eventually produce 36 rows in this fact table (plus any additional rows for failed attempts, reversals, or overpayments).

#### Measures

| Measure | Additivity | Notes |
|---|---|---|
| `payment_amount` | Fully additive | Total cash received for this event, in pence |
| `principal_portion` | Fully additive | Portion that reduces the outstanding loan balance |
| `interest_portion` | Fully additive | Portion that services accrued interest |
| `days_past_due` | **Non-additive** | Snapshot metric. Use `MAX()` (worst delinquency) or `AVG()` (portfolio health). **Never `SUM()`** |
| `outstanding_balance` | Semi-additive | Remaining balance after this payment. Meaningful per loan; not across loans |

---

## Raw Source Table Assumptions

The actual source data was not provided. The following column definitions represent assumptions made by the analytics engineer. **These must be validated against the real schema before the first `dbt run`.**

### `raw.customers`
One row per customer registration event.

| Column | Type | Assumption |
|---|---|---|
| `customer_id` | `varchar` | Natural key from CRM; source-system UUID |
| `first_name` | `varchar` | As supplied at KYC onboarding |
| `last_name` | `varchar` | As supplied at KYC onboarding |
| `date_of_birth` | `date` | |
| `email` | `varchar` | PII — will be hashed in the staging layer |
| `phone` | `varchar` | PII — will be hashed in the staging layer |
| `address_line_1` | `varchar` | |
| `address_city` | `varchar` | |
| `address_postcode` | `varchar` | UK postcode format |
| `address_country` | `varchar` | ISO 3166-1 alpha-2 (default `GB`) |
| `kyc_status` | `varchar` | `verified` / `pending` / `failed` |
| `customer_segment` | `varchar` | `retail` / `premium` / `student` |
| `created_at` | `timestamp` | Account opening timestamp (UTC) |
| `updated_at` | `timestamp` | Last CRM update — used for SCD Type 2 detection |

---

### `raw.accounts`
One row per account.

| Column | Type | Assumption |
|---|---|---|
| `account_id` | `varchar` | Natural key |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `account_type` | `varchar` | `current` / `savings` / `isa` |
| `product_name` | `varchar` | e.g. `Flex Saver`, `ClearCurrent` |
| `sort_code` | `varchar` | UK 6-digit sort code |
| `account_number` | `varchar` | UK 8-digit account number |
| `currency` | `varchar` | Assumed `GBP` for all domestic accounts |
| `opened_date` | `date` | |
| `closed_date` | `date` | `NULL` if still active |
| `status` | `varchar` | `active` / `dormant` / `closed` |

---

### `raw.transactions`
One row per posted transaction event.

| Column | Type | Assumption |
|---|---|---|
| `transaction_id` | `varchar` | Natural key; source-system UUID |
| `account_id` | `varchar` | FK → `raw.accounts` |
| `transaction_datetime` | `timestamp` | UTC. The date part drives `date_key` in the fact table |
| `value_date` | `date` | Settlement date — may differ from transaction date |
| `amount` | `integer` | In pence. Negative = debit, positive = credit |
| `running_balance` | `integer` | In pence, after this transaction is applied |
| `transaction_type` | `varchar` | `purchase` / `transfer_in` / `transfer_out` / `atm` / `direct_debit` / `fee` / `interest` |
| `channel` | `varchar` | `mobile_app` / `web` / `atm` / `branch` / `api` |
| `merchant_name` | `varchar` | Nullable; populated for card purchases only |
| `reference` | `varchar` | Free-text payment reference |
| `status` | `varchar` | `posted` / `pending` / `reversed` |

---

### `raw.loans`
One row per loan agreement.

| Column | Type | Assumption |
|---|---|---|
| `loan_id` | `varchar` | Natural key |
| `customer_id` | `varchar` | FK → `raw.customers` |
| `loan_type` | `varchar` | `personal` / `auto` / `overdraft` |
| `original_amount` | `integer` | In pence |
| `annual_interest_rate` | `decimal(6,4)` | e.g. `0.0749` for 7.49% APR |
| `term_months` | `integer` | |
| `disbursement_date` | `date` | When funds were released to the customer |
| `maturity_date` | `date` | Expected final repayment date |
| `status` | `varchar` | `active` / `settled` / `defaulted` / `written_off` |

---

### `raw.loan_repayments`
One row per repayment event.

| Column | Type | Assumption |
|---|---|---|
| `repayment_id` | `varchar` | Natural key |
| `loan_id` | `varchar` | FK → `raw.loans` |
| `payment_date` | `date` | Date payment was applied |
| `payment_amount` | `integer` | In pence |
| `principal_portion` | `integer` | In pence |
| `interest_portion` | `integer` | In pence |
| `outstanding_balance` | `integer` | In pence, after this payment |
| `days_past_due` | `integer` | `0` if paid on time |
| `payment_method` | `varchar` | `direct_debit` / `manual_transfer` / `card` |
| `status` | `varchar` | `completed` / `failed` / `reversed` |

---

### `raw.cards`
One row per card issued.

| Column | Type | Assumption |
|---|---|---|
| `card_id` | `varchar` | Natural key |
| `account_id` | `varchar` | FK → `raw.accounts` |
| `card_type` | `varchar` | `debit` / `virtual` |
| `issued_date` | `date` | |
| `expiry_date` | `date` | |
| `status` | `varchar` | `active` / `blocked` / `cancelled` |

---

## Dimension Table Designs

### `dim_customer` — SCD Type 2

Customers can change segment, address, and KYC status over time. SCD Type 2 preserves history so that a transaction in 2022 is correctly associated with the customer's segment *at that time*, not today's value.

| Column | Type | Notes |
|---|---|---|
| `customer_key` | `integer` | Surrogate PK (auto-increment) |
| `customer_id` | `varchar` | Natural key from source |
| `first_name` | `varchar` | |
| `last_name` | `varchar` | |
| `full_name` | `varchar` | Derived: `first_name \|\| ' ' \|\| last_name` |
| `date_of_birth` | `date` | |
| `age_band` | `varchar` | Derived: `18-24`, `25-34`, `35-44`, etc. |
| `kyc_status` | `varchar` | |
| `customer_segment` | `varchar` | |
| `address_city` | `varchar` | |
| `address_postcode` | `varchar` | |
| `valid_from` | `date` | SCD Type 2 effective start date |
| `valid_to` | `date` | SCD Type 2 effective end date (`9999-12-31` if current) |
| `is_current` | `boolean` | `TRUE` for the active record |

> **⚠️ PII Note:** `email` and `phone` are present in `raw.customers` but are **not** surfaced in `dim_customer`. They are hashed in staging (`stg_customers`) and omitted from the dimension entirely. Analytics queries do not require contact details.

---

### `dim_account` — SCD Type 2

Account status and product name can change (e.g. an account is closed, or a product is migrated). SCD Type 2 applied.

| Column | Type | Notes |
|---|---|---|
| `account_key` | `integer` | Surrogate PK |
| `account_id` | `varchar` | Natural key |
| `account_type` | `varchar` | |
| `product_name` | `varchar` | |
| `currency` | `varchar` | |
| `opened_date` | `date` | |
| `closed_date` | `date` | |
| `status` | `varchar` | |
| `valid_from` | `date` | |
| `valid_to` | `date` | |
| `is_current` | `boolean` | |

---

### `dim_date` — Static, Conformed ✦

A spine of every calendar date from `2015-01-01` to `2030-12-31`, pre-populated at build time. Not derived from source data — generated via a dbt macro (e.g. `dbt_utils.date_spine`).

**This is a conformed dimension.** It is shared by both `fact_transactions` and `fact_loan_repayments`, enabling cross-process analysis on a single, consistent date axis.

| Column | Type | Notes |
|---|---|---|
| `date_key` | `integer` | Surrogate PK in `YYYYMMDD` format (e.g. `20240315`) |
| `full_date` | `date` | |
| `day_of_week` | `varchar` | `Monday`, `Tuesday`, etc. |
| `day_of_week_num` | `integer` | `1` (Mon) to `7` (Sun) |
| `week_number` | `integer` | ISO week number |
| `month_num` | `integer` | 1–12 |
| `month_name` | `varchar` | `January`, etc. |
| `quarter` | `integer` | 1–4 |
| `year` | `integer` | Calendar year |
| `fiscal_year` | `integer` | ClearBank fiscal year (April start) |
| `fiscal_quarter` | `integer` | Relative to April start |
| `is_weekend` | `boolean` | `TRUE` for Saturday and Sunday |
| `is_uk_bank_holiday` | `boolean` | Pre-loaded from GOV.UK bank holiday API |

> **Why `YYYYMMDD` integer, not a `DATE` FK?** Integer joins are marginally faster on most warehouses, and the format is human-readable when browsing raw fact data. Either approach is valid; this is the chosen convention for ClearBank.

---

### `dim_channel` — Type 1

The set of channels changes rarely. Type 1 (overwrite in place) is sufficient. If a channel is renamed, the old name is updated and history is not preserved — this is acceptable for a small reference table.

| Column | Type | Notes |
|---|---|---|
| `channel_key` | `integer` | Surrogate PK |
| `channel_name` | `varchar` | `Mobile App`, `Web`, `ATM`, `Branch`, `API` |
| `channel_type` | `varchar` | `digital` / `physical` |
| `is_digital` | `boolean` | Derived from `channel_type` |

---

### `dim_transaction_type` — Type 1

A small lookup dimension. Adds a `direction` and `category` column, enabling analysts to slice by broad transaction category without string-matching on raw `transaction_type` values in every query.

| Column | Type | Notes |
|---|---|---|
| `txn_type_key` | `integer` | Surrogate PK |
| `type_name` | `varchar` | Raw value from source (e.g. `direct_debit`) |
| `type_label` | `varchar` | Display label (e.g. `Direct Debit`) |
| `category` | `varchar` | `payment` / `transfer` / `fee` / `interest` / `cash` |
| `direction` | `varchar` | `credit` / `debit` |

---

### `dim_loan` — Type 1

Loan terms are fixed at origination. Interest rate and term do not change for a given loan agreement. Type 1 is correct.

| Column | Type | Notes |
|---|---|---|
| `loan_key` | `integer` | Surrogate PK |
| `loan_id` | `varchar` | Natural key |
| `loan_type` | `varchar` | |
| `original_amount` | `integer` | In pence |
| `annual_interest_rate` | `decimal(6,4)` | |
| `term_months` | `integer` | |
| `disbursement_date` | `date` | |
| `maturity_date` | `date` | |
| `status` | `varchar` | |

---

### `dim_repayment_status` — Type 1

A small junk/lookup dimension grouping repayment outcomes into delinquency buckets. Decouples the delinquency classification logic from the fact table and allows easy re-bucketing without reloading facts.

| Column | Type | Notes |
|---|---|---|
| `status_key` | `integer` | Surrogate PK |
| `status_name` | `varchar` | `completed` / `failed` / `reversed` |
| `is_delinquent` | `boolean` | `TRUE` if `days_past_due > 0` at time of event |
| `delinquency_bucket` | `varchar` | `current` / `1-30 days` / `31-60 days` / `60+ days` / `written-off` |

---

## Star Schema Diagrams

### Schema 1 — `fact_transactions`

```
                    ┌─────────────────┐
                    │  dim_customer   │
                    │  (Type 2 SCD)   │
                    └────────┬────────┘
                             │ customer_key
              ┌──────────────▼──────────────────┐
┌─────────────┤        fact_transactions         ├─────────────┐
│             │  transaction_key (PK)            │             │
│             │  account_key     (FK)            │             │
│  dim_account│  customer_key    (FK)            │dim_channel  │
│  (Type 2)   │  date_key        (FK)            │(Type 1)     │
└─────────────┤  channel_key     (FK)            ├─────────────┘
              │  txn_type_key    (FK)            │
              │  ────────────────────            │
              │  transaction_amount              │
              │  running_balance                 │
              │  fee_amount                      │
              └──────────────┬──────────────────-┘
                             │ date_key
                    ┌────────▼────────┐
                    │    dim_date     │
                    │  ✦ conformed   │
                    └─────────────────┘
```

### Schema 2 — `fact_loan_repayments`

```
┌─────────────────┐                    ┌─────────────────┐
│    dim_loan     │                    │  dim_customer   │
│    (Type 1)     │                    │  ✦ conformed    │
└────────┬────────┘                    └────────┬────────┘
         │ loan_key                    customer_key │
         │         ┌──────────────────┐            │
         └─────────►  fact_loan_      ◄────────────┘
                   │  repayments      │
                   │                  │
  dim_repayment_   │  repayment_key   │
  status ──────────►  loan_key (FK)   │
  (Type 1)         │  customer_key FK │
                   │  date_key (FK)   │
                   │  status_key (FK) │
                   │  ─────────────── │
                   │  payment_amount  │
                   │  principal_      │
                   │    portion       │
                   │  interest_       │
                   │    portion       │
                   │  days_past_due   │
                   │  outstanding_    │
                   │    balance       │
                   └────────┬─────────┘
                            │ date_key
                   ┌────────▼────────┐
                   │    dim_date     │
                   │  ✦ conformed   │
                   └─────────────────┘
```

### Conformed Dimensions

| Dimension | Shared by |
|---|---|
| `dim_date` | `fact_transactions` and `fact_loan_repayments` |
| `dim_customer` | `fact_transactions` and `fact_loan_repayments` |

Conformed dimensions are the foundation of **cross-process analysis** — for example: *"For customers currently in arrears on a loan, what is their card spending pattern over the last 90 days?"* This query joins both fact tables through the shared `dim_customer` and `dim_date` dimensions without any hacks.

---

## Design Decisions & Key Assumptions

### Amounts stored as integers in pence

All monetary columns (`transaction_amount`, `payment_amount`, `principal_portion`, etc.) are stored as integers representing pence, not as `DECIMAL` or `FLOAT`. This avoids IEEE 754 floating-point rounding errors entirely. `£10.49` is stored as `1049`.

All formatting to `£` with two decimal places is handled in the BI tool or reporting layer, not in SQL.

### Surrogate keys on all dimensions

Natural keys from the source system (`customer_id`, `account_id`, etc.) are preserved as attributes in the dimension table but **surrogate integer keys drive all joins**. This:

- Insulates the warehouse from upstream key changes or replatforming
- Is required for SCD Type 2 (a single `customer_id` will have multiple surrogate keys — one per version)
- Produces smaller, faster join columns than UUIDs

### `dim_date` uses `YYYYMMDD` integer as the key

`date_key` is an integer in `YYYYMMDD` format rather than a `DATE` type. This is human-readable when browsing fact data, performs well on all major warehouses, and decouples the date dimension from SQL `DATE` casting semantics across dialects.

### `fact_transactions` excludes pending and reversed transactions

Only transactions with `status = 'posted'` are loaded into `fact_transactions`. Pending transactions are excluded to avoid double-counting. Reversed transactions are modelled as **offsetting rows** (a reversal produces a row with a negative amount in the opposite direction), preserving the full audit trail while keeping aggregate sums correct.

### `days_past_due` is explicitly non-additive

This is documented in the model's dbt schema YAML and in this document so analysts do not accidentally `SUM()` it. Correct aggregations:

| Use case | Aggregation |
|---|---|
| Worst delinquency in a period | `MAX(days_past_due)` |
| Portfolio health trend | `AVG(days_past_due)` |
| Count of accounts in arrears | `COUNT_IF(days_past_due > 0)` |

### SCD Type 2 on `dim_customer` and `dim_account`

Type 2 is chosen for these dimensions because **historical accuracy matters for regulatory and audit reporting**. A transaction in January 2023 must be attributed to the customer's segment as it was in January 2023, not as it is today. The `is_current = TRUE` filter is applied in the dbt model to retrieve present-day attributes for operational dashboards.

### PII is hashed in staging, not surfaced in dimensions

`email` and `phone` from `raw.customers` are hashed using a one-way function (e.g. `SHA-256`) in the `stg_customers` staging model and are not propagated to `dim_customer`. This ensures the analytics layer is compliant with ClearBank's data minimisation obligations under UK GDPR.

---

*Document prepared by: Analytics Engineering*
*Status: Draft — pending schema validation against production raw tables*
*Next step: Phase 1 — dbt project structure and staging models*
