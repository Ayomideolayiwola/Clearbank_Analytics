
with loans as (
    select * from {{ source('raw_clearbank', 'loans') }}
)

select
    loan_id,
    customer_id,
    account_id,
    loan_type,
    applied_amount,
    approved_amount,
    disbursed_amount,
    upfront_fee,
    currency,
    interest_rate,
    tenure_months,
    total_repayable,
    loan_status,
    application_date,
    approval_date,
    disbursement_date,
    created_at,
    updated_at
from loans


