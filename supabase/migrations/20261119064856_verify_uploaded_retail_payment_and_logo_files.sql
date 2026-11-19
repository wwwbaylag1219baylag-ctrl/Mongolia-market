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
  if p_receipt_path is null or split_part(p_receipt_path,'/',1) <> v_user::text
     or not exists (select 1 from storage.objects o where o.bucket_id='payment-receipts' and o.name=p_receipt_path) then
    raise exception 'Төлбөрийн баримтын файл олдсонгүй эсвэл зам буруу байна.';
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
       or not exists (select 1 from storage.objects o where o.bucket_id='market-store-logos' and o.name=p_pending_logo_path)
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

create or replace function public.nexora_update_free_store_logo(
  p_store_id uuid,
  p_logo_path text,
  p_market_type text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_fee bigint;
begin
  if v_user is null then raise exception 'Нэвтрэх шаардлагатай.'; end if;
  if p_market_type not in ('retail','wholesale') then raise exception 'Дэлгүүрийн төрөл буруу байна.'; end if;
  if p_logo_path is null or split_part(p_logo_path,'/',1) <> v_user::text
     or not exists (select 1 from storage.objects o where o.bucket_id='market-store-logos' and o.name=p_logo_path) then
    raise exception 'Логоны файл олдсонгүй эсвэл зам буруу байна.';
  end if;

  if p_market_type='retail' then
    select market_logo_fee into v_fee from public.nexora_settings where id=1;
    if coalesce(v_fee,0)<>0 then raise exception 'Онлайн дэлгүүрийн лого төлбөртэй тул баримт илгээнэ үү.'; end if;
    update public.nexora_store_profiles set logo_path=p_logo_path
    where id=p_store_id and user_id=v_user;
  else
    select wholesale_logo_fee into v_fee from public.nexora_settings where id=1;
    if coalesce(v_fee,0)<>0 then raise exception 'Нийлүүлэгчийн лого төлбөртэй тул баримт илгээнэ үү.'; end if;
    if not exists (select 1 from public.market_suppliers s where s.owner_id=v_user and s.status='approved') then
      raise exception 'Нийлүүлэгчийн эрх баталгаажаагүй байна.';
    end if;
    update public.nexora_store_profiles set wholesale_logo_path=p_logo_path
    where id=p_store_id and user_id=v_user;
  end if;
  if not found then raise exception 'Дэлгүүрийн профайл олдсонгүй.'; end if;
end;
$$;

revoke all on function public.nexora_submit_market_retail_fee_payment(text,uuid,uuid,text,uuid,text,text) from public, anon;
grant execute on function public.nexora_submit_market_retail_fee_payment(text,uuid,uuid,text,uuid,text,text) to authenticated;
revoke all on function public.nexora_update_free_store_logo(uuid,text,text) from public, anon;
grant execute on function public.nexora_update_free_store_logo(uuid,text,text) to authenticated;
