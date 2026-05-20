with account as (
    select * from {{ source('raw_clearbank', 'accounts') }}
)

select
    account_id,
    customer_id,
    account_type,
    account_number,
    sort_code,
    iban,
    currency,
    account_status,
    current_balance,
    available_balance,  
    interest_rate,
    opened_date,
    closed_date,
    created_at,
    updated_at
from account

