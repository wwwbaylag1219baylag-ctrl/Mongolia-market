alter table public.nexora_store_profiles
  add column if not exists wholesale_logo_path text;

create or replace function public.nexora_review_wholesale_fee_payment(
  p_payment_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  p public.wholesale_supplier_fee_payments%rowtype;
begin
  if not public.nexora_is_admin() then
    raise exception 'Зөвхөн админ шийдвэрлэнэ.';
  end if;
  select * into p
  from public.wholesale_supplier_fee_payments
  where id=p_payment_id
  for update;
  if not found then raise exception 'Төлбөрийн хүсэлт олдсонгүй.'; end if;
  if p.status <> 'pending' then raise exception 'Энэ төлбөр өмнө нь шийдвэрлэгдсэн байна.'; end if;

  if p_approve then
    if p.fee_type='product' then
      update public.wholesale_products
      set listing_fee_paid=true,
          status=case when content_approved then 'active' else 'pending' end,
          updated_at=now()
      where id=p.product_id and owner_id=p.user_id and status not in ('rejected','paused');
      if not found then raise exception 'Бөөний бараанд төлбөр холбох боломжгүй.'; end if;
    elsif p.fee_type='logo' then
      update public.nexora_store_profiles
      set wholesale_logo_path=p.pending_logo_path
      where id=p.store_id and user_id=p.user_id;
      if not found then raise exception 'Нийлүүлэгчийн дэлгүүрийн профайл олдсонгүй.'; end if;
    end if;
  end if;

  update public.wholesale_supplier_fee_payments
  set status=case when p_approve then 'approved' else 'rejected' end,
      admin_note=p_note,
      reviewed_by=auth.uid(),
      reviewed_at=now()
  where id=p_payment_id;
end;
$$;

revoke all on function public.nexora_review_wholesale_fee_payment(uuid,boolean,text) from public, anon;
grant execute on function public.nexora_review_wholesale_fee_payment(uuid,boolean,text) to authenticated;
