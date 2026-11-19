create or replace function public.nexora_cancel_market_unpaid_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.market_orders%rowtype;
  v_item jsonb;
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Нэвтрэх шаардлагатай.'; end if;
  select * into v_order
  from public.market_orders
  where id=p_order_id and buyer_id=v_user
  for update;
  if not found then raise exception 'Захиалга олдсонгүй эсвэл таны захиалга биш байна.'; end if;
  if v_order.status <> 'pending_payment' or v_order.payment_status <> 'unpaid' then
    raise exception 'Зөвхөн төлбөр хүлээж буй захиалгыг цуцалж болно.';
  end if;
  if exists (
    select 1 from public.market_order_payment_requests r
    where r.order_id=p_order_id and r.status='pending_review'
  ) then
    raise exception 'Төлбөрийн баримт хянагдаж байгаа тул одоогоор цуцлах боломжгүй.';
  end if;

  update public.market_orders
  set status='cancelled',payment_status='cancelled'
  where id=p_order_id;

  for v_item in select value from jsonb_array_elements(v_order.items) as x(value)
  loop
    update public.market_products
    set stock_quantity=stock_quantity+(v_item->>'quantity')::integer,
        updated_at=now()
    where id=(v_item->>'product_id')::uuid
      and owner_id=(v_item->>'seller_id')::uuid;
  end loop;
end;
$$;

revoke all on function public.nexora_cancel_market_unpaid_order(uuid) from public, anon;
grant execute on function public.nexora_cancel_market_unpaid_order(uuid) to authenticated;
