-- Sinalizacao Revisavel/Nao revisavel por imovel, oculta do acessocrm.

create table if not exists public.crm_property_reviewability (
  property_id text primary key,
  reviewable boolean not null default false,
  updated_by uuid not null references public.profiles(id),
  updated_at timestamptz not null default now()
);

alter table public.crm_property_reviewability enable row level security;
grant select on public.crm_property_reviewability to authenticated;

create policy "Non accesscrm users read property reviewability"
  on public.crm_property_reviewability
  for select
  using (auth.uid() is not null and not public.is_restricted_admin());

create or replace function public.set_property_reviewability(
  p_property_id text,
  p_reviewable boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null
     or public.is_restricted_admin() then
    raise exception 'Seu acesso nao permite alterar esta classificacao.';
  end if;

  insert into public.crm_property_reviewability (
    property_id,
    reviewable,
    updated_by,
    updated_at
  ) values (
    p_property_id,
    coalesce(p_reviewable, false),
    auth.uid(),
    now()
  )
  on conflict (property_id) do update set
    reviewable = excluded.reviewable,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.set_property_reviewability(text, boolean)
  from public, anon;
grant execute on function public.set_property_reviewability(text, boolean)
  to authenticated;
