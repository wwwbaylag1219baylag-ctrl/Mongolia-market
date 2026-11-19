revoke update on table public.nexora_store_profiles from authenticated;
grant update (store_name, owner_type, phone, description, address)
on table public.nexora_store_profiles to authenticated;

revoke insert on table public.nexora_store_profiles from authenticated;
grant insert (user_id, store_name, owner_type, phone, description, address)
on table public.nexora_store_profiles to authenticated;

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
  if p_logo_path is null or split_part(p_logo_path,'/',1) <> v_user::text then
    raise exception 'Логоны файлын зам буруу байна.';
  end if;

  if p_market_type='retail' then
    select market_logo_fee into v_fee from public.nexora_settings where id=1;
    if coalesce(v_fee,0)<>0 then raise exception 'Онлайн дэлгүүрийн лого төлбөртэй тул баримт илгээнэ үү.'; end if;
    update public.nexora_store_profiles
    set logo_path=p_logo_path
    where id=p_store_id and user_id=v_user;
  else
    select wholesale_logo_fee into v_fee from public.nexora_settings where id=1;
    if coalesce(v_fee,0)<>0 then raise exception 'Нийлүүлэгчийн лого төлбөртэй тул баримт илгээнэ үү.'; end if;
    if not exists (select 1 from public.market_suppliers s where s.owner_id=v_user and s.status='approved') then
      raise exception 'Нийлүүлэгчийн эрх баталгаажаагүй байна.';
    end if;
    update public.nexora_store_profiles
    set wholesale_logo_path=p_logo_path
    where id=p_store_id and user_id=v_user;
  end if;
  if not found then raise exception 'Дэлгүүрийн профайл олдсонгүй.'; end if;
end;
$$;

revoke all on function public.nexora_update_free_store_logo(uuid,text,text) from public, anon;
grant execute on function public.nexora_update_free_store_logo(uuid,text,text) to authenticated;
