create index if not exists market_retail_fee_payments_user_created_idx on public.market_retail_fee_payments(user_id,created_at desc);
create index if not exists market_retail_fee_payments_store_id_idx on public.market_retail_fee_payments(store_id);
create index if not exists market_retail_fee_payments_product_id_idx on public.market_retail_fee_payments(product_id);
create index if not exists market_retail_fee_payments_bank_account_id_idx on public.market_retail_fee_payments(bank_account_id);
create index if not exists market_retail_fee_payments_reviewed_by_idx on public.market_retail_fee_payments(reviewed_by);
