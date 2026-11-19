alter table public.market_products
  add column if not exists listing_fee_paid boolean not null default false,
  add column if not exists content_approved boolean not null default false;

update public.market_products
set listing_fee_paid = true,
    content_approved = (status = 'active')
where listing_fee_paid = false or content_approved = false;

create or replace function public.nexora_guard_market_product_owner_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  content_changed boolean;
  fee_is_free boolean;
begin
  if auth.uid() = new.owner_id and not public.nexora_is_admin() then
    if tg_op = 'INSERT' then
      select (market_product_listing_fee = 0)
        into fee_is_free
      from public.nexora_settings
      where id = 1;
      new.listing_fee_paid := coalesce(fee_is_free, false);
      new.content_approved := false;
      new.status := 'pending';
      return new;
    end if;

    if new.owner_id is distinct from old.owner_id then
      raise exception 'Барааны эзэмшигчийг өөрчлөх боломжгүй.';
    end if;
    if new.listing_fee_paid is distinct from old.listing_fee_paid
       or new.content_approved is distinct from old.content_approved
       or new.status is distinct from old.status then
      raise exception 'Төлбөр болон хяналтын төлөвийг зөвхөн админ өөрчилнө.';
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
      or new.min_order_quantity is distinct from old.min_order_quantity;

    if content_changed then
      new.content_approved := false;
      new.status := 'pending';
    end if;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_nexora_guard_market_product_owner_write on public.market_products;
create trigger trg_nexora_guard_market_product_owner_write
before insert or update on public.market_products
for each row execute function public.nexora_guard_market_product_owner_write();

create table if not exists public.market_retail_fee_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid references public.nexora_store_profiles(id) on delete cascade,
  product_id uuid references public.market_products(id) on delete cascade,
  fee_type text not null check (fee_type in ('logo','product')),
  pending_logo_path text,
  amount bigint not null check (amount > 0),
  bank_account_id uuid references public.bank_accounts(id),
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  transfer_reference text not null,
  receipt_path text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_note text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint market_retail_fee_payment_target_check check (
    (fee_type = 'logo' and store_id is not null and product_id is null and pending_logo_path is not null)
    or
    (fee_type = 'product' and product_id is not null and store_id is null and pending_logo_path is null)
  )
);

create unique index if not exists market_retail_fee_one_pending_request
on public.market_retail_fee_payments(user_id, fee_type, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(product_id, '00000000-0000-0000-0000-000000000000'::uuid))
where status = 'pending';

alter table public.market_retail_fee_payments enable row level security;
grant select on public.market_retail_fee_payments to authenticated;
grant insert on public.market_retail_fee_payments to authenticated;
revoke update, delete on public.market_retail_fee_payments from anon, authenticated;

drop policy if exists "Retail fee owner and admin can read" on public.market_retail_fee_payments;
create policy "Retail fee owner and admin can read"
on public.market_retail_fee_payments
for select to authenticated
using (user_id = (select auth.uid()) or (select public.nexora_is_admin()));

drop policy if exists "Retail fee owner can submit own request" on public.market_retail_fee_payments;
create policy "Retail fee owner can submit own request"
on public.market_retail_fee_payments
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and status = 'pending'
  and reviewed_by is null
  and reviewed_at is null
  and split_part(receipt_path, '/', 1) = (select auth.uid())::text
  and bank_account_id is not null
  and exists (select 1 from public.bank_accounts b where b.id = bank_account_id and b.is_active = true)
  and (
    (fee_type = 'logo' and exists (
      select 1 from public.nexora_store_profiles s
      where s.id = store_id and s.user_id = (select auth.uid())
    ))
    or
    (fee_type = 'product' and exists (
      select 1 from public.market_products p
      where p.id = product_id and p.owner_id = (select auth.uid()) and p.status = 'pending'
    ))
  )
);

create or replace function public.nexora_submit_market_retail_fee_payment(
  p_fee_type text,
  p_store_id uuid,
  p_product_id uuid,
  p_pending_logo_path text,
  p_bank_account_id uuid,
  p_transfer_reference text,
  p_receipt_path text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_amount bigint;
  v_bank public.bank_accounts%rowtype;
  v_payment_id uuid;
begin
  if v_user is null then raise exception 'Нэвтрэх шаардлагатай.'; end if;
  if p_fee_type not in ('logo','product') then raise exception 'Төлбөрийн төрөл буруу байна.'; end if;
  if nullif(btrim(p_transfer_reference),'') is null then raise exception 'Гүйлгээний утга оруулна уу.'; end if;
  if p_receipt_path is null or split_part(p_receipt_path,'/',1) <> v_user::text then
    raise exception 'Төлбөрийн баримтын зам буруу байна.';
  end if;

  select case when p_fee_type='logo' then market_logo_fee else market_product_listing_fee end
  into v_amount
  from public.nexora_settings where id=1;
  if coalesce(v_amount,0) <= 0 then raise exception 'Энэ үйлчилгээний төлбөр 0₮ байна.'; end if;

  select * into v_bank from public.bank_accounts
  where id=p_bank_account_id and is_active=true;
  if not found then raise exception 'Идэвхтэй банкны данс сонгоно уу.'; end if;

  if p_fee_type='logo' then
    if p_store_id is null or p_product_id is not null or p_pending_logo_path is null
       or split_part(p_pending_logo_path,'/',1) <> v_user::text
       or not exists (select 1 from public.nexora_store_profiles s where s.id=p_store_id and s.user_id=v_user) then
      raise exception 'Онлайн дэлгүүрийн логоны хүсэлт буруу байна.';
    end if;
  else
    if p_product_id is null or p_store_id is not null or p_pending_logo_path is not null
       or not exists (select 1 from public.market_products p where p.id=p_product_id and p.owner_id=v_user and p.status='pending') then
      raise exception 'Жижиглэнгийн барааны төлбөрийн хүсэлт буруу байна.';
    end if;
  end if;

  insert into public.market_retail_fee_payments(
    user_id,store_id,product_id,fee_type,pending_logo_path,amount,
    bank_account_id,bank_name,account_number,account_holder,
    transfer_reference,receipt_path,status
  ) values (
    v_user,p_store_id,p_product_id,p_fee_type,p_pending_logo_path,v_amount,
    v_bank.id,v_bank.bank_name,v_bank.account_number,v_bank.account_holder,
    btrim(p_transfer_reference),p_receipt_path,'pending'
  ) returning id into v_payment_id;

  return v_payment_id;
end;
$$;

revoke all on function public.nexora_submit_market_retail_fee_payment(text,uuid,uuid,text,uuid,text,text) from public, anon;
grant execute on function public.nexora_submit_market_retail_fee_payment(text,uuid,uuid,text,uuid,text,text) to authenticated;

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
  select * into v_payment from public.market_retail_fee_payments
  where id=p_payment_id for update;
  if not found then raise exception 'Төлбөрийн хүсэлт олдсонгүй.'; end if;
  if v_payment.status <> 'pending' then raise exception 'Энэ төлбөр өмнө нь шийдвэрлэгдсэн байна.'; end if;

  if p_approve then
    if v_payment.fee_type='logo' then
      update public.nexora_store_profiles
      set logo_path=v_payment.pending_logo_path
      where id=v_payment.store_id and user_id=v_payment.user_id;
      if not found then raise exception 'Онлайн дэлгүүрийн профайл олдсонгүй.'; end if;
    else
      update public.market_products
      set listing_fee_paid=true,
          status=case when content_approved then 'active' else 'pending' end,
          updated_at=now()
      where id=v_payment.product_id and owner_id=v_payment.user_id and status <> 'rejected';
      if not found then raise exception 'Жижиглэнгийн бараанд төлбөр холбох боломжгүй.'; end if;
    end if;
  end if;

  update public.market_retail_fee_payments
  set status=case when p_approve then 'approved' else 'rejected' end,
      admin_note=p_note,
      reviewed_by=auth.uid(),
      reviewed_at=now()
  where id=p_payment_id;
end;
$$;

revoke all on function public.nexora_review_market_retail_fee_payment(uuid,boolean,text) from public, anon;
grant execute on function public.nexora_review_market_retail_fee_payment(uuid,boolean,text) to authenticated;

create or replace function public.nexora_review_market_retail_product(
  p_product_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.nexora_is_admin() then raise exception 'Зөвхөн админ шийдвэрлэнэ.'; end if;
  if p_approve then
    update public.market_products
    set content_approved=true,
        status=case when listing_fee_paid then 'active' else 'pending' end
    where id=p_product_id and status <> 'rejected';
  else
    update public.market_products
    set content_approved=false,status='rejected'
    where id=p_product_id;
  end if;
  if not found then raise exception 'Жижиглэнгийн бараа олдсонгүй эсвэл өмнө нь татгалзсан байна.'; end if;
end;
$$;

revoke all on function public.nexora_review_market_retail_product(uuid,boolean) from public, anon;
grant execute on function public.nexora_review_market_retail_product(uuid,boolean) to authenticated;
