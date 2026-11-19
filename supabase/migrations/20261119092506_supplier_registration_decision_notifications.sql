-- Supplier registration decisions notify the applicant immediately.
create table if not exists public.market_supplier_registration_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  payment_id uuid not null references public.market_supplier_registration_payments(id) on delete cascade,
  title text not null,
  message text not null,
  decision text not null check (decision in ('approved','rejected')),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint market_supplier_registration_notifications_payment_unique unique(payment_id)
);

create index if not exists market_supplier_registration_notifications_user_created_idx
  on public.market_supplier_registration_notifications(user_id, created_at desc);

alter table public.market_supplier_registration_notifications enable row level security;
grant select on public.market_supplier_registration_notifications to authenticated;
grant update(read_at) on public.market_supplier_registration_notifications to authenticated;

drop policy if exists "Supplier registration notifications owner/admin read" on public.market_supplier_registration_notifications;
create policy "Supplier registration notifications owner/admin read"
on public.market_supplier_registration_notifications for select to authenticated
using (user_id = (select auth.uid()) or (select public.nexora_is_admin()));

drop policy if exists "Supplier registration notifications owner mark read" on public.market_supplier_registration_notifications;
create policy "Supplier registration notifications owner mark read"
on public.market_supplier_registration_notifications for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'market_supplier_registration_notifications'
  ) then
    alter publication supabase_realtime add table public.market_supplier_registration_notifications;
  end if;
end $$;

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
  v_note text;
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
  where id=v_payment.supplier_id
    and owner_id=v_payment.user_id
    and status='pending';

  if not found then raise exception 'Нийлүүлэгчийн хүсэлт олдсонгүй эсвэл өмнө нь шийдвэрлэгдсэн байна.'; end if;

  v_note := nullif(btrim(p_note), '');

  update public.market_supplier_registration_payments
  set status=case when p_approve then 'approved' else 'rejected' end,
      admin_note=v_note,
      reviewed_by=auth.uid(),
      reviewed_at=now()
  where id=p_payment_id;

  insert into public.market_supplier_registration_notifications
    (user_id, payment_id, title, message, decision)
  values (
    v_payment.user_id,
    v_payment.id,
    case when p_approve then 'Нийлүүлэгчийн бүртгэл зөвшөөрөгдлөө' else 'Нийлүүлэгчийн бүртгэлээс татгалзлаа' end,
    case
      when p_approve then 'Админ таны нийлүүлэгчээр бүртгүүлэх хүсэлтийг зөвшөөрлөө. Нийлүүлэгчийн профайлдаа нэвтэрч үйл ажиллагаагаа эхлүүлээрэй.'
      else 'Админ таны нийлүүлэгчээр бүртгүүлэх хүсэлтийг татгалзлаа. Шалтгаан: ' || coalesce(v_note, 'Админаас дэлгэрэнгүй тайлбар өгөөгүй.') || ' Та бүртгэлтэй хэрэглэгчээрээ дахин нэвтэрч, мэдээллээ засварлан хүсэлтээ дахин илгээх боломжтой.'
    end,
    case when p_approve then 'approved' else 'rejected' end
  );
end;
$$;

revoke all on function public.nexora_review_supplier_registration_payment(uuid,boolean,text) from public, anon;
grant execute on function public.nexora_review_supplier_registration_payment(uuid,boolean,text) to authenticated;
