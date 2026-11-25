alter table public.wholesale_orders alter column buyer_id drop not null;

create or replace function public.nexora_create_guest_wholesale_order(
  p_product_id uuid,
  p_quantity integer,
  p_buyer_name text,
  p_buyer_phone text,
  p_delivery_address text default '',
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.wholesale_products%rowtype;
  v_order_id uuid;
begin
  if p_product_id is null then raise exception 'Бараа сонгоно уу.'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Захиалгын тоо хэмжээ буруу байна.'; end if;
  if length(btrim(coalesce(p_buyer_name,''))) < 2 or length(btrim(coalesce(p_buyer_name,''))) > 120 then raise exception 'Хүлээн авагчийн нэрээ зөв оруулна уу.'; end if;
  if length(regexp_replace(coalesce(p_buyer_phone,''),'[^0-9+]','','g')) < 8 or length(coalesce(p_buyer_phone,'')) > 32 then raise exception 'Утасны дугаараа зөв оруулна уу.'; end if;
  if length(coalesce(p_delivery_address,'')) > 500 or length(coalesce(p_note,'')) > 1000 then raise exception 'Хаяг эсвэл тайлбар хэт урт байна.'; end if;

  select * into v_product
  from public.wholesale_products
  where id = p_product_id and status = 'active'
    and listing_fee_paid = true and content_approved = true
  for update;
  if not found then raise exception 'Бөөний бараа олдсонгүй эсвэл захиалах боломжгүй байна.'; end if;
  if p_quantity < v_product.min_order_quantity or p_quantity > v_product.stock_quantity then raise exception 'Захиалгын тоо хэмжээ доод хэмжээ эсвэл үлдэгдлийн шаардлага хангахгүй байна.'; end if;
  if not exists (select 1 from public.market_suppliers s where s.owner_id = v_product.owner_id and s.status = 'approved') then raise exception 'Нийлүүлэгч одоогоор захиалга авах боломжгүй байна.'; end if;

  insert into public.wholesale_orders (
    buyer_id,supplier_id,items,total_amount,status,buyer_name,buyer_phone,delivery_address,note
  ) values (
    null,v_product.owner_id,
    jsonb_build_array(jsonb_build_object('product_id',v_product.id,'quantity',p_quantity)),
    0,'pending',btrim(p_buyer_name),btrim(p_buyer_phone),
    btrim(coalesce(p_delivery_address,'')),btrim(coalesce(p_note,''))
  ) returning id into v_order_id;
  return v_order_id;
end;
$$;

revoke all on function public.nexora_create_guest_wholesale_order(uuid,integer,text,text,text,text) from public;
grant execute on function public.nexora_create_guest_wholesale_order(uuid,integer,text,text,text,text) to anon, authenticated;