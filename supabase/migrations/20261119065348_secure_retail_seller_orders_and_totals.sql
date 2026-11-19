create or replace function public.nexora_reserve_market_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_product public.market_products%rowtype;
  v_qty integer;
  v_expected_price numeric;
  v_tier jsonb;
  v_total numeric := 0;
  v_calculated_items jsonb := '[]'::jsonb;
begin
  if new.buyer_id is distinct from (select auth.uid()) then
    raise exception 'Захиалга үүсгэгч хэрэглэгч баталгаажаагүй байна.';
  end if;
  if jsonb_typeof(new.items) is distinct from 'array' or jsonb_array_length(new.items) = 0 then
    raise exception 'Захиалгын барааны жагсаалт хоосон байна.';
  end if;

  for v_item in select value from jsonb_array_elements(new.items) as x(value)
  loop
    select * into v_product
    from public.market_products
    where id = (v_item->>'product_id')::uuid
      and status = 'active'
    for update;

    if not found then
      raise exception 'Захиалсан бараа идэвхгүй эсвэл олдсонгүй.';
    end if;

    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < v_product.min_order_quantity then
      raise exception 'Захиалгын доод хэмжээнээс бага тоо байна.';
    end if;
    if v_qty > v_product.stock_quantity then
      raise exception 'Барааны үлдэгдэл хүрэлцэхгүй байна: %', v_product.title;
    end if;
    if v_product.owner_id = new.buyer_id then
      raise exception 'Өөрийн дэлгүүрийн барааг өөрөө захиалах боломжгүй.';
    end if;
    if (v_item->>'seller_id')::uuid is distinct from v_product.owner_id then
      raise exception 'Дэлгүүрийн эзэмшигчийн мэдээлэл зөрүүтэй байна.';
    end if;

    v_expected_price := v_product.price;
    select value into v_tier
    from jsonb_array_elements(coalesce(v_product.wholesale_price_tiers, '[]'::jsonb)) as x(value)
    where (value->>'min_qty')::integer <= v_qty
    order by (value->>'min_qty')::integer desc
    limit 1;
    if v_tier is not null then
      v_expected_price := (v_tier->>'price')::numeric;
    end if;

    v_calculated_items := v_calculated_items || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,
      'title',v_product.title,
      'unit_price',v_expected_price,
      'quantity',v_qty,
      'seller_id',v_product.owner_id
    ));
    v_total := v_total + v_expected_price * v_qty;

    update public.market_products
    set stock_quantity = stock_quantity - v_qty
    where id = v_product.id;
  end loop;

  new.items := v_calculated_items;
  new.total_amount := v_total;
  new.status := 'pending_payment';
  new.payment_status := 'unpaid';
  return new;
end;
$$;

drop policy if exists "Sellers view own retail orders" on public.market_orders;
create policy "Sellers view own retail orders"
on public.market_orders
for select to authenticated
using (
  exists (
    select 1
    from jsonb_array_elements(items) as item
    where item->>'seller_id' = (select auth.uid())::text
  )
);

create index if not exists market_orders_items_gin_idx
on public.market_orders using gin(items jsonb_path_ops);

create or replace function public.nexora_complete_market_seller_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.market_orders%rowtype;
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Нэвтрэх шаардлагатай.'; end if;
  select * into v_order
  from public.market_orders
  where id=p_order_id
  for update;
  if not found then raise exception 'Захиалга олдсонгүй.'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_order.items) as item
    where item->>'seller_id'=v_user::text
  ) then
    raise exception 'Энэ захиалга таны дэлгүүрт хамаарахгүй байна.';
  end if;
  if v_order.payment_status <> 'paid' or v_order.status <> 'processing' then
    raise exception 'Төлбөр баталгаажиж, захиалга бэлтгэгдсэн төлөвт орсны дараа дуусгах боломжтой.';
  end if;
  update public.market_orders set status='completed' where id=p_order_id;
end;
$$;

revoke all on function public.nexora_complete_market_seller_order(uuid) from public, anon;
grant execute on function public.nexora_complete_market_seller_order(uuid) to authenticated;
