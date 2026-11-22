alter table public.market_products add column if not exists delivery_available boolean not null default false;
alter table public.wholesale_products add column if not exists delivery_available boolean not null default false;
