drop policy if exists "Sellers view own retail orders" on public.market_orders;

create or replace function public.nexora_get_retail_seller_orders()
returns table(
  order_id uuid,
  items jsonb,
  seller_total numeric,
  status text,
  payment_status text,
  recipient_name text,
  delivery_phone text,
  delivery_address text,
  delivery_latitude numeric,
  delivery_longitude numeric,
  delivery_note text,
  created_at timestamptz
)
language sql
security definer
set search_path = ''
as $$
  select
    o.id,
    coalesce((
      select jsonb_agg(item.value)
      from jsonb_array_elements(o.items) as item(value)
      where item.value->>'seller_id'=(select auth.uid())::text
    ),'[]'::jsonb),
    coalesce((
      select sum((item.value->>'unit_price')::numeric*(item.value->>'quantity')::integer)
      from jsonb_array_elements(o.items) as item(value)
      where item.value->>'seller_id'=(select auth.uid())::text
    ),0),
    o.status,
    o.payment_status,
    o.recipient_name,
    o.delivery_phone,
    o.delivery_address,
    o.delivery_latitude,
    o.delivery_longitude,
    o.delivery_note,
    o.created_at
  from public.market_orders o
  where (select auth.uid()) is not null
    and o.items @> jsonb_build_array(jsonb_build_object('seller_id',(select auth.uid())::text))
  order by o.created_at desc
  limit 100;
$$;

revoke all on function public.nexora_get_retail_seller_orders() from public, anon;
grant execute on function public.nexora_get_retail_seller_orders() to authenticated;
