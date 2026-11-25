alter table public.wholesale_orders
  add column if not exists delivery_latitude double precision,
  add column if not exists delivery_longitude double precision;
alter table public.wholesale_orders drop constraint if exists wholesale_orders_delivery_coordinates_check;
alter table public.wholesale_orders add constraint wholesale_orders_delivery_coordinates_check
  check ((delivery_latitude is null and delivery_longitude is null) or (delivery_latitude between -90 and 90 and delivery_longitude between -180 and 180));

create or replace function public.nexora_sync_wholesale_order_to_unified()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.nexora_orders(legacy_source,legacy_order_id,buyer_id,seller_id,items,total_amount,status,payment_status,recipient_name,delivery_phone,delivery_address,delivery_latitude,delivery_longitude,delivery_note,created_at,updated_at,legacy_payload)
  values ('wholesale_orders',new.id,new.buyer_id,new.supplier_id,new.items,new.total_amount,new.status,new.payment_status,new.buyer_name,new.buyer_phone,new.delivery_address,new.delivery_latitude,new.delivery_longitude,new.note,new.created_at,new.updated_at,to_jsonb(new))
  on conflict (legacy_source,legacy_order_id) do update set buyer_id=excluded.buyer_id,seller_id=excluded.seller_id,items=excluded.items,total_amount=excluded.total_amount,status=excluded.status,payment_status=excluded.payment_status,recipient_name=excluded.recipient_name,delivery_phone=excluded.delivery_phone,delivery_address=excluded.delivery_address,delivery_latitude=excluded.delivery_latitude,delivery_longitude=excluded.delivery_longitude,delivery_note=excluded.delivery_note,updated_at=excluded.updated_at,legacy_payload=excluded.legacy_payload;
  return new;
end;
$$;

drop function if exists public.nexora_create_guest_wholesale_order(uuid,integer,text,text,text,text);
create function public.nexora_create_guest_wholesale_order(p_product_id uuid,p_quantity integer,p_buyer_name text,p_buyer_phone text,p_delivery_address text default '',p_note text default '',p_delivery_latitude double precision default null,p_delivery_longitude double precision default null)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_product public.wholesale_products%rowtype; v_order_id uuid;
begin
  if p_product_id is null then raise exception 'Бараа сонгоно уу.'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Захиалгын тоо хэмжээ буруу байна.'; end if;
  if length(btrim(coalesce(p_buyer_name,''))) < 2 or length(btrim(coalesce(p_buyer_name,''))) > 120 then raise exception 'Хүлээн авагчийн нэрээ зөв оруулна уу.'; end if;
  if length(regexp_replace(coalesce(p_buyer_phone,''),'[^0-9+]','','g')) < 8 or length(coalesce(p_buyer_phone,'')) > 32 then raise exception 'Утасны дугаараа зөв оруулна уу.'; end if;
  if length(coalesce(p_delivery_address,'')) > 500 or length(coalesce(p_note,'')) > 1000 then raise exception 'Тайлбар хэт урт байна.'; end if;
  if (p_delivery_latitude is null) <> (p_delivery_longitude is null) or (p_delivery_latitude is not null and (p_delivery_latitude < -90 or p_delivery_latitude > 90 or p_delivery_longitude < -180 or p_delivery_longitude > 180)) then raise exception 'Хүргэлтийн байршлыг газрын зураг дээр зөв сонгоно уу.'; end if;
  if p_delivery_latitude is null then raise exception 'Хүргэлтийн байршлаа газрын зураг дээр тэмдэглэнэ үү.'; end if;
  select * into v_product from public.wholesale_products where id=p_product_id and status='active' and listing_fee_paid=true and content_approved=true for update;
  if not found then raise exception 'Бөөний бараа олдсонгүй эсвэл захиалах боломжгүй байна.'; end if;
  if p_quantity < v_product.min_order_quantity or p_quantity > v_product.stock_quantity then raise exception 'Захиалгын тоо хэмжээ доод хэмжээ эсвэл үлдэгдлийн шаардлага хангахгүй байна.'; end if;
  if not exists(select 1 from public.market_suppliers s where s.owner_id=v_product.owner_id and s.status='approved') then raise exception 'Нийлүүлэгч одоогоор захиалга авах боломжгүй байна.'; end if;
  insert into public.wholesale_orders(buyer_id,supplier_id,items,total_amount,status,buyer_name,buyer_phone,delivery_address,delivery_latitude,delivery_longitude,note)
  values(null,v_product.owner_id,jsonb_build_array(jsonb_build_object('product_id',v_product.id,'quantity',p_quantity)),0,'pending',btrim(p_buyer_name),btrim(p_buyer_phone),btrim(coalesce(p_delivery_address,'')),p_delivery_latitude,p_delivery_longitude,btrim(coalesce(p_note,'')))
  returning id into v_order_id;
  return v_order_id;
end;
$$;
revoke all on function public.nexora_create_guest_wholesale_order(uuid,integer,text,text,text,text,double precision,double precision) from public;
grant execute on function public.nexora_create_guest_wholesale_order(uuid,integer,text,text,text,text,double precision,double precision) to anon,authenticated;