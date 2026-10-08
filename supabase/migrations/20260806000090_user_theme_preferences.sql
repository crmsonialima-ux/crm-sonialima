-- Preferencia de tema individual e persistente por acesso.
alter table public.profiles
  add column if not exists preferred_theme text not null default 'dark';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_preferred_theme_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_preferred_theme_check
      check (preferred_theme in ('dark', 'light'));
  end if;
end;
$$;

create or replace function public.set_my_preferred_theme(p_theme text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;
  if p_theme not in ('dark', 'light') then
    raise exception 'Tema invalido.';
  end if;

  update public.profiles
  set preferred_theme = p_theme
  where id = auth.uid();
end;
$$;

revoke all on function public.set_my_preferred_theme(text) from public, anon;
grant execute on function public.set_my_preferred_theme(text) to authenticated;
