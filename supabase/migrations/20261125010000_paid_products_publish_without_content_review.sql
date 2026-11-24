-- Paid product listings publish immediately; content approval is no longer a separate admin step.
create or replace function public.nexora_guard_market_product_owner_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  content_changed boolean;
  fee_is_free boolean;
  has_entitlement boolean;
begin
  if auth.uid() = new.owner_id and not public.nexora_is_admin() then
    if tg_op = 'INSERT' then
      has_entitlement := public.nexora_has_active_posting_entitlement(new.owner_id);
      select (market_product_listing_fee = 0)
        into fee_is_free
      from public.nexora_settings
      where id = 1;
      new.listing_fee_paid := coalesce(has_entitlement, false) or coalesce(fee_is_free, false);
      new.content_approved := new.listing_fee_paid;
      new.status := case when new.listing_fee_paid then 'active' else 'pending' end;
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

create or replace function public.nexora_guard_wholesale_product_insert_entitlement()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() = new.owner_id and not public.nexora_is_admin() then
    if not public.nexora_has_active_posting_entitlement(new.owner_id) then
      raise exception 'Нийтлэх 30 хоногийн эрх идэвхгүй байна.';
    end if;
    new.listing_fee_paid := true;
    new.content_approved := true;
    new.status := 'active';
  end if;
  return new;
end;
$$;

create or replace function public.nexora_guard_wholesale_product_owner_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  content_changed boolean;
begin
  if auth.uid() = old.owner_id and not public.nexora_is_admin() then
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
      or new.image_paths is distinct from old.image_paths
      or new.wholesale_price_tiers is distinct from old.wholesale_price_tiers
      or new.min_order_quantity is distinct from old.min_order_quantity;

    if content_changed then
      new.content_approved := coalesce(new.listing_fee_paid, false);
      new.status := case when new.listing_fee_paid then 'active' else 'pending' end;
    end if;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create or replace function public.nexora_review_market_retail_fee_payment(
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
  v_payment public.market_retail_fee_payments%rowtype;
begin
  if not public.nexora_is_admin() then raise exception 'Зөвхөн админ шийдвэрлэнэ.'; end if;
  select * into v_payment
  from public.market_retail_fee_payments
  where id = p_payment_id
  for update;
  if not found then raise exception 'Төлбөрийн хүсэлт олдсонгүй.'; end if;
  if v_payment.status <> 'pending' then raise exception 'Энэ төлбөр өмнө нь шийдвэрлэгдсэн байна.'; end if;

  if p_approve then
    if v_payment.fee_type = 'logo' then
      update public.nexora_store_profiles
      set logo_path = v_payment.pending_logo_path
      where id = v_payment.store_id and user_id = v_payment.user_id;
      if not found then raise exception 'Онлайн дэлгүүрийн профайл олдсонгүй.'; end if;
    else
      update public.market_products
      set listing_fee_paid = true,
          content_approved = true,
          status = 'active',
          updated_at = now()
      where id = v_payment.product_id
        and owner_id = v_payment.user_id
        and status <> 'rejected';
      if not found then raise exception 'Жижиглэнгийн бараанд төлбөр холбох боломжгүй.'; end if;
    end if;
  end if;

  update public.market_retail_fee_payments
  set status = case when p_approve then 'approved' else 'rejected' end,
      admin_note = p_note,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = p_payment_id;
end;
$$;

create or replace function public.nexora_review_wholesale_fee_payment(
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
  v_payment public.wholesale_supplier_fee_payments%rowtype;
begin
  if not public.nexora_is_admin() then
    raise exception 'Зөвхөн админ шийдвэрлэнэ.';
  end if;
  select * into v_payment
  from public.wholesale_supplier_fee_payments
  where id = p_payment_id
  for update;
  if not found then raise exception 'Төлбөрийн хүсэлт олдсонгүй.'; end if;
  if v_payment.status <> 'pending' then raise exception 'Энэ төлбөр өмнө нь шийдвэрлэгдсэн байна.'; end if;

  if p_approve then
    if v_payment.fee_type = 'product' then
      update public.wholesale_products
      set listing_fee_paid = true,
          content_approved = true,
          status = 'active',
          updated_at = now()
      where id = v_payment.product_id
        and owner_id = v_payment.user_id
        and status not in ('rejected', 'paused');
      if not found then raise exception 'Бөөний бараанд төлбөр холбох боломжгүй.'; end if;
    elsif v_payment.fee_type = 'logo' then
      update public.nexora_store_profiles
      set wholesale_logo_path = v_payment.pending_logo_path
      where id = v_payment.store_id and user_id = v_payment.user_id;
      if not found then raise exception 'Нийлүүлэгчийн дэлгүүрийн профайл олдсонгүй.'; end if;
    end if;
  end if;

  update public.wholesale_supplier_fee_payments
  set status = case when p_approve then 'approved' else 'rejected' end,
      admin_note = p_note,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = p_payment_id;
end;
$$;

update public.market_products
set content_approved = true, status = 'active', updated_at = now()
where listing_fee_paid = true and status = 'pending';

update public.wholesale_products
set content_approved = true, status = 'active', updated_at = now()
where listing_fee_paid = true and status = 'pending';
