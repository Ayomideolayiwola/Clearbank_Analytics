with loan_repay as (
    select * from {{ source('clearbank_raw', 'loan_repayments') }}
)

select
    repayment_id,
    loan_id,
    customer_id,
    account_id,
    scheduled_repayment_date,
    actual_payment_date,
    amount_due,
    amount_paid,
    principal_component,
    interest_component,
    late_fee,
    days_late,
    payment_method,
    repayment_status,
    created_at,
    updated_at
from loan_repay