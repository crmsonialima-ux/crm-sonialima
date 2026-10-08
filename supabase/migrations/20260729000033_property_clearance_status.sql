create table if not exists public.crm_property_clearance_status (
  property_id text primary key references public.crm_property_document_responsibilities(external_id) on delete cascade,
  status text not null check (status in ('Nada consta', 'Consta')),
  updated_by uuid not null references public.profiles(id),
  updated_at timestamptz not null default now()
);

alter table public.crm_property_clearance_status enable row level security;
grant select on public.crm_property_clearance_status to authenticated;

create policy "Authenticated users read property clearance status"
  on public.crm_property_clearance_status for select
  using (auth.uid() is not null);

create or replace function public.set_property_clearance_status(
  p_property_id text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('Nada consta', 'Consta') then
    raise exception 'Status inválido.';
  end if;

  if not exists (
    select 1
    from public.crm_property_document_responsibilities
    where external_id = p_property_id
      and broker_id = auth.uid()
  ) then
    raise exception 'Somente o corretor responsável pode alterar o nada consta deste imóvel.';
  end if;

  insert into public.crm_property_clearance_status (property_id, status, updated_by, updated_at)
  values (p_property_id, p_status, auth.uid(), now())
  on conflict (property_id) do update set
    status = excluded.status,
    updated_by = excluded.updated_by,
    updated_at = now();
end;
$$;

grant execute on function public.set_property_clearance_status(text, text) to authenticated;
