create or replace function public.nexora_review_market_retail_product(
  p_product_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fee_is_free boolean;
begin
  if not public.nexora_is_admin() then raise exception 'Зөвхөн админ шийдвэрлэнэ.'; end if;
  select (market_product_listing_fee = 0) into v_fee_is_free
  from public.nexora_settings where id=1;
  if p_approve then
    update public.market_products
    set listing_fee_paid = listing_fee_paid or coalesce(v_fee_is_free,false),
        content_approved=true,
        status=case when listing_fee_paid or coalesce(v_fee_is_free,false) then 'active' else 'pending' end
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
