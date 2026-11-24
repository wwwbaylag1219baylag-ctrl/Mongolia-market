-- Require the same paid 30-day posting entitlement for retail listings as for wholesale listings.
create or replace function public.nexora_guard_market_product_owner_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  content_changed boolean;
  has_entitlement boolean;
begin
  if auth.uid() = new.owner_id and not public.nexora_is_admin() then
    if tg_op = 'INSERT' then
      has_entitlement := public.nexora_has_active_posting_entitlement(new.owner_id);
      if not coalesce(has_entitlement, false) then
        raise exception 'Нийтлэх 30 хоногийн эрх идэвхгүй байна.';
      end if;
      new.listing_fee_paid := true;
      new.content_approved := true;
      new.status := 'active';
      return new;
    end if;

    if new.owner_id is distinct from old.owner_id then
      raise exception 'Барааны эзэмшигчийг өөрчлөх боломжгүй.';
    end if;
    if new.listing_fee_paid is distinct from old.listing_fee_paid
       or new.content_approved is distinct from old.content_approved
       or new.status is distinct from old.status then
      raise exception 'Төлбөр болон нийтлэлийн төлөвийг зөвхөн систем өөрчилнө.';
    end if;

    content_changed :=
      new.title is distinct from old.title
      or new.category is distinct from old.category
      or new.price is distinct from old.price
      or new.description is distinct from old.description
      or new.phone is distinct from old.phone
      or new.location is distinct from old.location
      or new.image_path is distinct from old.image_path
      or new.stock_quantity is distinct from old.stock_quantity
      or new.min_order_quantity is distinct from old.min_order_quantity
      or new.product_logo_path is distinct from old.product_logo_path;

    if content_changed then
      new.content_approved := coalesce(new.listing_fee_paid, false);
      new.status := case when new.listing_fee_paid then 'active' else 'pending' end;
    end if;
    new.updated_at := now();
  end if;
  return new;
end;
$$;