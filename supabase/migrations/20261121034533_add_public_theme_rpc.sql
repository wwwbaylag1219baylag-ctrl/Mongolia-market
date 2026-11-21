create or replace function public.nexora_get_public_theme()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (select s.admin_theme_config
     from public.nexora_settings as s
     where s.id = 1),
    '{}'::jsonb
  );
$function$;

revoke all on function public.nexora_get_public_theme() from public;
grant execute on function public.nexora_get_public_theme() to anon, authenticated;

comment on function public.nexora_get_public_theme()
is 'Returns only the public NEXORA theme configuration; does not expose other admin settings.';
