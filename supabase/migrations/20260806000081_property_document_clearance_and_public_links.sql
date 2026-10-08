-- O status Consta/Nada consta pertence a cada documento, nao ao imovel inteiro.
drop function if exists public.set_property_clearance_status(text, text);
drop table if exists public.crm_property_clearance_status cascade;

create table if not exists public.crm_property_document_clearance_status (
  property_id text not null,
  document_id text not null check (
    document_id in (
      'certidao-onus',
      'certidao-iptu',
      'pgfn',
      'tjdft',
      'trf1-criminal',
      'trf1-civil',
      'trt10',
      'tst',
      'sefaz-df'
    )
  ),
  status text not null check (status in ('Nada consta', 'Consta')),
  updated_by uuid not null references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key (property_id, document_id)
);

alter table public.crm_property_document_clearance_status enable row level security;
grant select on public.crm_property_document_clearance_status to authenticated;

create policy "Authenticated users read property document clearance status"
  on public.crm_property_document_clearance_status
  for select
  using (auth.uid() is not null);

create or replace function public.set_property_document_clearance_status(
  p_property_id text,
  p_document_id text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_document_id not in (
    'certidao-onus',
    'certidao-iptu',
    'pgfn',
    'tjdft',
    'trf1-criminal',
    'trf1-civil',
    'trt10',
    'tst',
    'sefaz-df'
  ) then
    raise exception 'Documento invalido.';
  end if;

  if not public.has_full_admin_access()
     and not exists (
       select 1
       from public.crm_property_document_responsibilities as responsibility
       where responsibility.external_id = p_property_id
         and responsibility.broker_id = auth.uid()
     )
     and not exists (
       select 1
       from public.crm_property_broker_access as access
       where access.property_id = p_property_id
         and access.broker_id = auth.uid()
     ) then
    raise exception 'Somente o corretor responsavel ou um administrador autorizado pode alterar este status.';
  end if;

  if nullif(trim(coalesce(p_status, '')), '') is null then
    delete from public.crm_property_document_clearance_status
    where property_id = p_property_id
      and document_id = p_document_id;
    return;
  end if;

  if p_status not in ('Nada consta', 'Consta') then
    raise exception 'Status invalido.';
  end if;

  insert into public.crm_property_document_clearance_status (
    property_id,
    document_id,
    status,
    updated_by,
    updated_at
  ) values (
    p_property_id,
    p_document_id,
    p_status,
    auth.uid(),
    now()
  )
  on conflict (property_id, document_id) do update set
    status = excluded.status,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.set_property_document_clearance_status(text, text, text)
  from public, anon;
grant execute on function public.set_property_document_clearance_status(text, text, text)
  to authenticated;

-- Link publico opcional exibido pelo botao "Ver imovel".
create table if not exists public.crm_property_public_links (
  property_id text primary key,
  url text not null,
  updated_by uuid not null references public.profiles(id),
  updated_at timestamptz not null default now()
);

alter table public.crm_property_public_links enable row level security;
grant select on public.crm_property_public_links to authenticated;

create policy "Authenticated users read property public links"
  on public.crm_property_public_links
  for select
  using (auth.uid() is not null);

create or replace function public.sync_property_public_link(
  p_property_id text,
  p_url text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_url text := trim(coalesce(p_url, ''));
begin
  if auth.uid() is null or public.is_restricted_admin() then
    raise exception 'Seu acesso nao permite editar o link do imovel.';
  end if;

  if normalized_url = '' then
    delete from public.crm_property_public_links
    where property_id = p_property_id;
    return;
  end if;

  if normalized_url !~* '^https?://' then
    raise exception 'Informe um link completo iniciado por http:// ou https://.';
  end if;

  insert into public.crm_property_public_links (property_id, url, updated_by, updated_at)
  values (p_property_id, normalized_url, auth.uid(), now())
  on conflict (property_id) do update set
    url = excluded.url,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.sync_property_public_link(text, text)
  from public, anon;
grant execute on function public.sync_property_public_link(text, text)
  to authenticated;
