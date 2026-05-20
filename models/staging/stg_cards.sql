with cards as (
    select * from {{ source('clearbank_raw', 'cards') }}
)

select
    card_id,
    account_id,
    customer_id,
    card_type,
    card_network,
    card_status,
    is_contactless_enabled,
    is_online_enabled,
    is_international_enabled,
    daily_withdrawal_limit,
    issued_date,
    activation_date,
    expires_at,
    cancelled_at,
    created_at,
    updated_at
from cards