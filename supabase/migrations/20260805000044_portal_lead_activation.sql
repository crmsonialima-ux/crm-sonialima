-- Controle administrativo do recebimento de leads pelos portais.
-- O portal pode permanecer configurado; somente o CRM decide se cria leads.
create table if not exists public.crm_portal_lead_integrations (
  provider text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

alter table public.crm_portal_lead_integrations enable row level security;

drop policy if exists "Admins read portal lead integrations" on public.crm_portal_lead_integrations;
create policy "Admins read portal lead integrations"
  on public.crm_portal_lead_integrations for select to authenticated
  using (public.is_admin());

insert into public.crm_portal_lead_integrations (provider, enabled)
values ('wimoveis_vrsync', false)
on conflict (provider) do nothing;

create or replace function public.set_portal_lead_integration_enabled(
  p_provider text,
  p_enabled boolean
)
returns public.crm_portal_lead_integrations
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.crm_portal_lead_integrations;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem alterar integrações de leads.';
  end if;

  if p_provider <> 'wimoveis_vrsync' then
    raise exception 'Integração não reconhecida.';
  end if;

  insert into public.crm_portal_lead_integrations (provider, enabled, updated_at, updated_by)
  values (p_provider, p_enabled, now(), auth.uid())
  on conflict (provider) do update
    set enabled = excluded.enabled,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by
  returning * into result;

  return result;
end;
$$;

revoke all on function public.set_portal_lead_integration_enabled(text, boolean) from public;
grant execute on function public.set_portal_lead_integration_enabled(text, boolean) to authenticated;
