alter table public.market_products add column if not exists updated_at timestamptz not null default now();
