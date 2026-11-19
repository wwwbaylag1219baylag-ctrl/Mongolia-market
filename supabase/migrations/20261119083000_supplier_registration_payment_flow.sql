create table if not exists public.market_supplier_registration_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  supplier_id uuid not null references public.market_suppliers(id) on delete cascade,
  owner_type text not null check (owner_type in ('individual','company')),
  supplier_name text not null,
  supplier_type text,
  register_no text,
  phone text,
  email text,
  address text,
  amount bigint not null check (amount in (150000,350000)),
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
  constraint market_supplier_registration_owner_amount_check
    check ((owner_type='individual' and amount=150000) or (owner_type='company' and amount=350000))
);

create unique index if not exists market_supplier_registration_one_pending_per_user
  on public.market_supplier_registration_payments(user_id)
  where status='pending';

create index if not exists market_supplier_registration_created_at_idx
  on public.market_supplier_registration_payments(created_at desc);

alter table public.market_supplier_registration_payments enable row level security;
grant select, insert on public.market_supplier_registration_payments to authenticated;

drop policy if exists "Supplier registration payment owner/admin read" on public.market_supplier_registration_payments;
create policy "Supplier registration payment owner/admin read"
on public.market_supplier_registration_payments for select to authenticated
using (user_id=(select auth.uid()) or (select public.nexora_is_admin()));

drop policy if exists "Supplier submits own registration payment" on public.market_supplier_registration_payments;
create policy "Supplier submits own registration payment"
on public.market_supplier_registration_payments for insert to authenticated
with check (
  user_id=(select auth.uid())
  and status='pending'
  and reviewed_by is null
  and reviewed_at is null
  and ((owner_type='individual' and amount=150000) or (owner_type='company' and amount=350000))
  and split_part(receipt_path,'/',1)=(select auth.uid())::text
  and exists (
    select 1 from public.market_suppliers s
    where s.id=supplier_id
      and s.owner_id=(select auth.uid())
      and s.owner_type=owner_type
      and s.status='pending'
  )
  and exists (
    select 1 from public.bank_accounts b
    where b.id=bank_account_id and b.is_active=true
  )
);

create or replace function public.nexora_review_supplier_registration_payment(
  p_payment_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_payment public.market_supplier_registration_payments%rowtype;
begin
  if not public.nexora_is_admin() then
    raise exception 'Зөвхөн админ шийдвэрлэнэ.';
  end if;

  select * into v_payment
  from public.market_supplier_registration_payments
  where id=p_payment_id
  for update;

  if not found then raise exception 'Нийлүүлэгчийн бүртгэлийн төлбөр олдсонгүй.'; end if;
  if v_payment.status <> 'pending' then raise exception 'Энэ төлбөр өмнө нь шийдвэрлэгдсэн байна.'; end if;

  update public.market_suppliers
  set status=case when p_approve then 'approved' else 'rejected' end
  where id=v_payment.supplier_id and owner_id=v_payment.user_id and status='pending';

  if not found then raise exception 'Нийлүүлэгчийн хүсэлт олдсонгүй эсвэл өмнө нь шийдвэрлэгдсэн байна.'; end if;

  update public.market_supplier_registration_payments
  set status=case when p_approve then 'approved' else 'rejected' end,
      admin_note=p_note,
      reviewed_by=auth.uid(),
      reviewed_at=now()
  where id=p_payment_id;
end;
$$;

revoke all on function public.nexora_review_supplier_registration_payment(uuid,boolean,text) from public, anon;
grant execute on function public.nexora_review_supplier_registration_payment(uuid,boolean,text) to authenticated;
