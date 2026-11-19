create or replace function public.nexora_review_market_order_payment(
  p_payment_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_items jsonb;
  v_item jsonb;
begin
  if not (select public.nexora_is_admin()) then
    raise exception 'Зөвшөөрөлгүй хэрэглэгч';
  end if;

  update public.market_order_payment_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      admin_note = p_note,
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_payment_id
    and status = 'pending_review'
  returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'Захиалгын төлбөрийн хүсэлт олдсонгүй эсвэл шийдвэрлэгдсэн байна';
  end if;

  update public.market_orders
  set payment_status = case when p_approve then 'paid' else 'rejected' end,
      status = case when p_approve then 'processing' else 'payment_rejected' end
  where id = v_order_id
    and payment_status = 'unpaid'
    and status = 'pending_payment'
  returning items into v_items;

  if v_items is null then
    raise exception 'Захиалгын төлөв тохирохгүй байна';
  end if;

  if not p_approve then
    for v_item in select value from jsonb_array_elements(v_items) as x(value)
    loop
      update public.market_products
      set stock_quantity = stock_quantity + (v_item->>'quantity')::integer,
          updated_at = now()
      where id = (v_item->>'product_id')::uuid
        and owner_id = (v_item->>'seller_id')::uuid;
    end loop;
  end if;
end;
$$;

revoke all on function public.nexora_review_market_order_payment(uuid,boolean,text) from public, anon;
grant execute on function public.nexora_review_market_order_payment(uuid,boolean,text) to authenticated;
