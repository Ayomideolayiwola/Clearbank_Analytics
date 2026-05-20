with transactions as (
    select * from {{ source('clearbank_raw', 'transactions') }}
)

select
    transaction_id,
    account_id,
    customer_id,
    transaction_date,
    transaction_type,
    counterpart_name,
    counterpart_acc_no,
    counterpart_sort_code,
    direction,
    transaction_amount,
    currency,
    balance_after,
    status,
    channel,
    reference,
    initiated_at,
    settled_at,
    created_at
from transactions

