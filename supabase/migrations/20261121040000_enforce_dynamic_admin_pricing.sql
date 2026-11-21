create or replace function public.nexora_validate_classified_ad_package()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_config jsonb;
  v_package jsonb;
  v_expected_days integer;
  v_expected_amount integer;
  v_free_limit integer;
  v_used_basic_ads integer;
begin
  if auth.uid() is null or new.owner_id is distinct from auth.uid() then
    raise exception 'Зарын эзэмшигчийн мэдээлэл буруу байна.';
  end if;
  select s.ad_package_config into v_config
  from public.nexora_settings as s where s.id = 1;
  if not found then raise exception 'Зарын үнийн тохиргоо олдсонгүй.'; end if;
  v_package := v_config -> new.package_type;
  if v_package is null or jsonb_typeof(v_package) <> 'object' then
    raise exception 'Сонгосон зарын багц идэвхгүй байна.';
  end if;
  v_expected_days := nullif(v_package ->> 'days', '')::integer;
  v_expected_amount := coalesce(nullif(v_package ->> 'amount', '')::integer, 0);
  if v_expected_days is null or v_expected_days < 1 or v_expected_days > 365 or v_expected_amount < 0 then
    raise exception 'Зарын багцын тохиргоо буруу байна.';
  end if;
  if new.package_type = 'basic' then
    perform pg_advisory_xact_lock(hashtextextended(new.owner_id::text, 0));
    select count(*)::integer into v_used_basic_ads
    from public.classified_ads as a
    where a.owner_id = new.owner_id and a.package_type = 'basic';
    v_free_limit := greatest(0, coalesce(nullif(v_package ->> 'free_limit', '')::integer, 1));
    if v_used_basic_ads < v_free_limit then v_expected_amount := 0; end if;
  end if;
  if new.package_days is distinct from v_expected_days or new.package_amount is distinct from v_expected_amount then
    raise exception 'Зарын багцын үнэ эсвэл хугацаа админы одоогийн тохиргоотой таарахгүй байна.';
  end if;
  if new.status is distinct from (case when v_expected_amount = 0 then 'pending_review' else 'pending_payment' end) then
    raise exception 'Зарын төлөв багцын төлбөртэй тохирохгүй байна.';
  end if;
  new.expires_at := now() + make_interval(days => v_expected_days);
  return new;
end;
$function$;

drop trigger if exists nexora_validate_classified_ad_package on public.classified_ads;
create trigger nexora_validate_classified_ad_package
before insert on public.classified_ads
for each row execute function public.nexora_validate_classified_ad_package();

create or replace function public.nexora_protect_classified_ad_package_fields()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if not public.nexora_is_admin() then
    if new.owner_id is distinct from old.owner_id
       or new.package_type is distinct from old.package_type
       or new.package_days is distinct from old.package_days
       or new.package_amount is distinct from old.package_amount
       or new.status is distinct from old.status
       or new.expires_at is distinct from old.expires_at then
      raise exception 'Зарын багц, төлбөр болон төлөвийг зөвхөн систем удирдана.';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists nexora_protect_classified_ad_package_fields on public.classified_ads;
create trigger nexora_protect_classified_ad_package_fields
before update on public.classified_ads
for each row execute function public.nexora_protect_classified_ad_package_fields();

drop policy if exists "Users can submit own package ads" on public.classified_ads;
create policy "Users can submit own package ads"
on public.classified_ads for insert to authenticated
with check (
  owner_id = (select auth.uid())
  and package_type in ('basic', 'featured', 'vip', 'premium')
  and status in ('pending_review', 'pending_payment')
);

drop policy if exists "Users can edit own pending basic ads" on public.classified_ads;
create policy "Users can edit own pending basic ads"
on public.classified_ads for update to authenticated
using (owner_id = (select auth.uid()) and status = 'pending_review' and package_type = 'basic' and package_amount = 0)
with check (owner_id = (select auth.uid()) and status = 'pending_review' and package_type = 'basic' and package_amount = 0);

create or replace function public.nexora_validate_payment_request_insert()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_package_amount integer;
  v_package_days integer;
begin
  if auth.uid() is null or new.user_id is distinct from auth.uid() then
    raise exception 'Төлбөрийн хүсэлт илгээхийн тулд нэвтэрнэ үү.';
  end if;
  select a.package_amount, a.package_days into v_package_amount, v_package_days
  from public.classified_ads as a
  where a.id = new.ad_id and a.owner_id = auth.uid() and a.status = 'pending_payment'
  for update;
  if not found then raise exception 'Төлбөр хүлээж буй таны зар олдсонгүй.'; end if;
  if new.amount is distinct from v_package_amount::numeric or new.package_days is distinct from v_package_days then
    raise exception 'Төлбөрийн дүн эсвэл хугацаа зарын багцтай таарахгүй байна.';
  end if;
  if new.status is distinct from 'pending_review' or new.reviewed_at is not null then
    raise exception 'Төлбөрийн хүсэлтийн төлөв буруу байна.';
  end if;
  return new;
end;
$function$;

drop trigger if exists nexora_validate_payment_request_insert on public.payment_requests;
create trigger nexora_validate_payment_request_insert
before insert on public.payment_requests
for each row execute function public.nexora_validate_payment_request_insert();

create or replace function public.nexora_validate_store_payment_insert()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_owner_type text;
  v_expected_amount bigint;
begin
  if auth.uid() is null or new.user_id is distinct from auth.uid() then
    raise exception 'Дэлгүүрийн төлбөр илгээхийн тулд нэвтэрнэ үү.';
  end if;
  select p.owner_type into v_owner_type
  from public.nexora_store_profiles as p
  where p.id = new.store_id and p.user_id = auth.uid();
  if not found then raise exception 'Таны дэлгүүрийн профайл олдсонгүй.'; end if;
  select case when v_owner_type = 'company' then s.company_price else s.individual_price end
    into v_expected_amount
  from public.nexora_settings as s where s.id = 1;
  if not found then raise exception 'Дэлгүүрийн төлбөрийн тохиргоо олдсонгүй.'; end if;
  if new.amount is distinct from v_expected_amount then
    raise exception 'Дэлгүүрийн төлбөр админы одоогийн суурь үнэтэй таарахгүй байна.';
  end if;
  if new.status is distinct from 'pending' or new.subscription_id is not null
     or new.reviewed_by is not null or new.reviewed_at is not null then
    raise exception 'Дэлгүүрийн төлбөрийн хүсэлтийн төлөв буруу байна.';
  end if;
  if nullif(btrim(new.transfer_reference), '') is null then
    raise exception 'Гүйлгээний утгаа оруулна уу.';
  end if;
  return new;
end;
$function$;

drop trigger if exists nexora_validate_store_payment_insert on public.nexora_store_payments;
create trigger nexora_validate_store_payment_insert
before insert on public.nexora_store_payments
for each row execute function public.nexora_validate_store_payment_insert();

create or replace function public.admin_approve_payment_request(p_request_id uuid)
returns void
language plpgsql
set search_path = ''
as $function$
declare
  v_ad_id uuid;
  v_ad_days integer;
  v_ad_amount integer;
  v_payment_days integer;
  v_payment_amount numeric;
begin
  if not public.nexora_is_admin() then raise exception 'Зөвшөөрөлгүй хэрэглэгч'; end if;
  select p.ad_id, p.package_days, p.amount, a.package_days, a.package_amount
    into v_ad_id, v_payment_days, v_payment_amount, v_ad_days, v_ad_amount
  from public.payment_requests as p
  join public.classified_ads as a on a.id = p.ad_id and a.owner_id = p.user_id
  where p.id = p_request_id and p.status = 'pending_review' and a.status = 'pending_payment'
  for update of p, a;
  if not found then raise exception 'Төлбөрийн хүсэлт олдсонгүй эсвэл өмнө нь шийдвэрлэгдсэн байна'; end if;
  if v_payment_amount is distinct from v_ad_amount::numeric or v_payment_days is distinct from v_ad_days then
    raise exception 'Төлбөрийн хүсэлт зарын анхны багцтай таарахгүй байна.';
  end if;
  update public.payment_requests set status = 'approved', reviewed_at = now()
  where id = p_request_id and status = 'pending_review';
  update public.classified_ads set status = 'active', expires_at = now() + make_interval(days => v_ad_days)
  where id = v_ad_id and status = 'pending_payment';
  if not found then raise exception 'Төлбөртэй зарын төлөв тохирохгүй байна'; end if;
end;
$function$;

create or replace function public.admin_review_free_ad(p_ad_id uuid, p_approve boolean)
returns void
language plpgsql
set search_path = ''
as $function$
begin
  if not public.nexora_is_admin() then raise exception 'Зөвшөөрөлгүй хэрэглэгч'; end if;
  update public.classified_ads
  set status = case when p_approve then 'active' else 'rejected' end,
      expires_at = case when p_approve then now() + make_interval(days => package_days) else expires_at end
  where id = p_ad_id and status = 'pending_review' and package_amount = 0;
  if not found then raise exception 'Үнэгүй зар олдсонгүй эсвэл өмнө нь шийдвэрлэгдсэн байна'; end if;
end;
$function$;

create index if not exists market_supplier_registration_payments_bank_account_id_idx
  on public.market_supplier_registration_payments (bank_account_id);
create index if not exists market_supplier_registration_payments_reviewed_by_idx
  on public.market_supplier_registration_payments (reviewed_by);
create index if not exists market_supplier_registration_payments_supplier_id_idx
  on public.market_supplier_registration_payments (supplier_id);

-- Keep the database constraints compatible with admin-configured amounts and durations.
alter table public.payment_requests
  drop constraint if exists payment_requests_package_amount_check,
  drop constraint if exists payment_requests_package_days_check;
alter table public.payment_requests
  add constraint payment_requests_package_amount_check check (amount >= 0),
  add constraint payment_requests_package_days_check check (package_days between 1 and 365);

alter table public.nexora_store_payments
  drop constraint if exists nexora_store_payments_amount_check;
alter table public.nexora_store_payments
  add constraint nexora_store_payments_amount_check check (amount >= 0);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.nexora_settings'::regclass
      and conname='nexora_settings_store_pricing_check'
  ) then
    alter table public.nexora_settings
      add constraint nexora_settings_store_pricing_check
      check (individual_price >= 0 and company_price >= 0 and duration_days between 1 and 365);
  end if;
end
$$;
