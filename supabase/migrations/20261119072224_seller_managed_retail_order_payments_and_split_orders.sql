create or replace function public.nexora_create_market_seller_orders(
  p_items jsonb,
  p_recipient_name text,
  p_delivery_phone text,
  p_delivery_address text,
  p_delivery_latitude double precision,
  p_delivery_longitude double precision,
  p_delivery_note text
)
returns table(order_id uuid, total_amount numeric, seller_id uuid)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_buyer uuid := (select auth.uid());
  v_group record;
  v_new_order_id uuid;
  v_total numeric;
begin
  if v_buyer is null then
    raise exception 'Захиалга үүсгэхийн тулд нэвтэрнэ үү.';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Захиалгын барааны жагсаалт хоосон байна.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_items) as x(item)
    where nullif(x.item->>'seller_id', '') is null
  ) then
    raise exception 'Барааны худалдагчийн мэдээлэл дутуу байна.';
  end if;

  for v_group in
    select
      (x.item->>'seller_id')::uuid as seller_id,
      jsonb_agg(x.item) as seller_items
    from jsonb_array_elements(p_items) as x(item)
    group by (x.item->>'seller_id')::uuid
  loop
    insert into public.market_orders (
      buyer_id, items, total_amount, status, payment_status,
      recipient_name, delivery_phone, delivery_address,
      delivery_latitude, delivery_longitude, delivery_note
    )
    values (
      v_buyer, v_group.seller_items, 0, 'pending_payment', 'unpaid',
      p_recipient_name, p_delivery_phone, p_delivery_address,
      p_delivery_latitude, p_delivery_longitude, p_delivery_note
    )
    returning id, market_orders.total_amount
    into v_new_order_id, v_total;

    order_id := v_new_order_id;
    total_amount := v_total;
    seller_id := v_group.seller_id;
    return next;
  end loop;
end;
$$;

revoke all on function public.nexora_create_market_seller_orders(jsonb,text,text,text,double precision,double precision,text) from public, anon;
grant execute on function public.nexora_create_market_seller_orders(jsonb,text,text,text,double precision,double precision,text) to authenticated;

create or replace function public.nexora_seller_review_market_order_payment(
  p_order_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_order public.market_orders%rowtype;
  v_seller_count integer;
  v_item jsonb;
begin
  if v_user is null then
    raise exception 'Нэвтрэх шаардлагатай.';
  end if;
  if p_approve is null then
    raise exception 'Төлбөрийн шийдвэр тодорхойгүй байна.';
  end if;

  select *
  into v_order
  from public.market_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Захиалга олдсонгүй.';
  end if;

  select count(distinct x.item->>'seller_id')
  into v_seller_count
  from jsonb_array_elements(coalesce(v_order.items, '[]'::jsonb)) as x(item);

  if v_seller_count <> 1 or not exists (
    select 1
    from jsonb_array_elements(v_order.items) as x(item)
    where x.item->>'seller_id' = v_user::text
  ) then
    raise exception 'Зөвхөн өөрийн дэлгүүрийн тусдаа захиалгыг шийдвэрлэх боломжтой.';
  end if;

  if v_order.payment_status <> 'unpaid' or v_order.status <> 'pending_payment' then
    raise exception 'Энэ захиалгын төлбөр өмнө нь шийдвэрлэгдсэн эсвэл захиалгын төлөв өөрчлөгдсөн байна.';
  end if;

  if p_approve then
    update public.market_orders
    set payment_status = 'paid',
        status = 'processing'
    where id = p_order_id;
  else
    update public.market_orders
    set payment_status = 'rejected',
        status = 'payment_rejected'
    where id = p_order_id;

    for v_item in
      select x.item from jsonb_array_elements(v_order.items) as x(item)
    loop
      update public.market_products
      set stock_quantity = stock_quantity + (v_item->>'quantity')::integer,
          updated_at = now()
      where id = (v_item->>'product_id')::uuid
        and owner_id = v_user;
    end loop;
  end if;
end;
$$;

revoke all on function public.nexora_seller_review_market_order_payment(uuid,boolean) from public, anon;
grant execute on function public.nexora_seller_review_market_order_payment(uuid,boolean) to authenticated;

revoke all on function public.nexora_review_market_order_payment(uuid,boolean,text) from public, anon, authenticated;

drop policy if exists "NEXORA admins update orders" on public.market_orders;
drop policy if exists "NEXORA admins view all orders" on public.market_orders;

drop policy if exists "Buyers and admins view order payment requests" on public.market_order_payment_requests;
create policy "Buyers view own order payment requests"
on public.market_order_payment_requests
for select to authenticated
using (buyer_id = (select auth.uid()));

drop policy if exists "NEXORA admins update order payment requests" on public.market_order_payment_requests;
drop policy if exists "Buyers submit own order payment requests" on public.market_order_payment_requests;

drop policy if exists "Store owners and buyers can read seller bank accounts" on public.store_bank_accounts;
create policy "Store owners and buyers can read seller bank accounts"
on public.store_bank_accounts
for select to authenticated
using (
  (select auth.uid()) = user_id
  or exists (
    select 1
    from public.market_products p
    where p.owner_id = store_bank_accounts.user_id
      and p.status = 'active'
  )
  or exists (
    select 1
    from public.market_orders o
    where o.buyer_id = (select auth.uid())
      and o.items @> jsonb_build_array(
        jsonb_build_object('seller_id', store_bank_accounts.user_id::text)
      )
  )
);
