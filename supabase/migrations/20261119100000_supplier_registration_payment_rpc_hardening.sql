create or replace function public.nexora_submit_supplier_registration_payment(
  p_supplier_id uuid,
  p_owner_type text,
  p_supplier_name text,
  p_supplier_type text,
  p_register_no text,
  p_phone text,
  p_email text,
  p_address text,
  p_amount bigint,
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
  v_bank public.bank_accounts%rowtype;
  v_supplier public.market_suppliers%rowtype;
  v_payment_id uuid := gen_random_uuid();
begin
  if v_user is null then
    raise exception 'Нэвтрэх шаардлагатай.';
  end if;

  if p_owner_type not in ('individual','company')
     or (p_owner_type='individual' and p_amount<>150000)
     or (p_owner_type='company' and p_amount<>350000) then
    raise exception 'Бүртгэлийн төлбөрийн дүн буруу байна.';
  end if;

  if nullif(btrim(p_transfer_reference),'') is null then
    raise exception 'Гүйлгээний утгаа оруулна уу.';
  end if;

  if p_receipt_path is null
     or split_part(p_receipt_path,'/',1) <> v_user::text
     or not exists (
       select 1 from storage.objects o
       where o.bucket_id='payment-receipts'
         and o.name=p_receipt_path
     ) then
    raise exception 'Төлбөрийн баримтын файл баталгаажаагүй байна.';
  end if;

  select * into v_bank
  from public.bank_accounts
  where id=p_bank_account_id and is_active=true;
  if not found then
    raise exception 'Идэвхтэй банкны данс сонгоно уу.';
  end if;

  select * into v_supplier
  from public.market_suppliers
  where id=p_supplier_id
    and owner_id=v_user
    and owner_type=p_owner_type
    and status='pending'
  for update;
  if not found then
    raise exception 'Нийлүүлэгчийн хүсэлт pending төлөвт олдсонгүй. Маягтаа дахин илгээнэ үү.';
  end if;

  insert into public.market_supplier_registration_payments(
    id,user_id,supplier_id,owner_type,supplier_name,supplier_type,
    register_no,phone,email,address,amount,bank_account_id,
    bank_name,account_number,account_holder,transfer_reference,
    receipt_path,status
  ) values (
    v_payment_id,v_user,p_supplier_id,p_owner_type,p_supplier_name,
    p_supplier_type,p_register_no,p_phone,p_email,p_address,p_amount,
    p_bank_account_id,v_bank.bank_name,v_bank.account_number,
    v_bank.account_holder,btrim(p_transfer_reference),p_receipt_path,'pending'
  );

  return v_payment_id;
end;
$$;

revoke all on function public.nexora_submit_supplier_registration_payment(
  uuid,text,text,text,text,text,text,text,bigint,uuid,text,text
) from public, anon;
grant execute on function public.nexora_submit_supplier_registration_payment(
  uuid,text,text,text,text,text,text,text,bigint,uuid,text,text
) to authenticated;