with customer as (
    select * from {{ source('clearbank_raw', 'customers') }}
)

select
    customer_id,
    first_name,
    middle_name,
    last_name,
    date_of_birth,
    email,
    phone_number_1,
    phone_number_2,
    address_line_1,
    address_line_2,
    city,
    country,
    kyc_status,
    customer_segment,
    aquisition_channel,
    referral_code_used,
    is_active,
    created_at,
    updated_at
from customer