create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.nexora_seller_review_market_order_payment(
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

revoke all on function private.nexora_seller_review_market_order_payment(uuid,boolean) from public, anon;
grant execute on function private.nexora_seller_review_market_order_payment(uuid,boolean) to authenticated;

create or replace function public.nexora_seller_review_market_order_payment(
  p_order_id uuid,
  p_approve boolean
)
returns void
language sql
security invoker
set search_path = ''
as $$
  select private.nexora_seller_review_market_order_payment(p_order_id, p_approve);
$$;

revoke all on function public.nexora_seller_review_market_order_payment(uuid,boolean) from public, anon;
grant execute on function public.nexora_seller_review_market_order_payment(uuid,boolean) to authenticated;
