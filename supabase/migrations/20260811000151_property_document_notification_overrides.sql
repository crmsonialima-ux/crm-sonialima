begin;

create table if not exists public.crm_property_document_notification_overrides (
  property_id text primary key references public.crm_property_catalog(external_id) on delete cascade,
  enabled boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

alter table public.crm_property_document_notification_overrides enable row level security;
revoke all on table public.crm_property_document_notification_overrides from public, anon, authenticated;

create or replace function public.get_property_document_notification_states()
returns table (
  property_id text,
  override_enabled boolean,
  effective_enabled boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select
    catalog.external_id,
    override_row.enabled,
    coalesce(override_row.enabled, settings.property_document_notifications_enabled, true)
  from public.crm_property_catalog as catalog
  left join public.crm_property_document_notification_overrides as override_row
    on override_row.property_id = catalog.external_id
  left join public.crm_operational_settings as settings on settings.singleton
  where auth.uid() is not null;
$$;

create or replace function public.set_property_document_notification_override(
  p_property_id text,
  p_enabled boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode controlar os avisos de documentos por imovel.';
  end if;

  if not exists (
    select 1 from public.crm_property_catalog where external_id = trim(p_property_id)
  ) then
    raise exception 'Imovel nao encontrado.';
  end if;

  insert into public.crm_property_document_notification_overrides (
    property_id, enabled, updated_at, updated_by
  ) values (
    trim(p_property_id), p_enabled, now(), auth.uid()
  )
  on conflict (property_id) do update
  set enabled = excluded.enabled,
      updated_at = excluded.updated_at,
      updated_by = excluded.updated_by;

  if not p_enabled then
    delete from public.crm_notification_outbox as notification
    where notification.kind = 'property_document_reminder'
      and notification.delivered_at is null
      and notification.payload ->> 'propertyId' = trim(p_property_id);
  end if;

  return p_enabled;
end;
$$;

revoke all on function public.get_property_document_notification_states()
  from public, anon;
grant execute on function public.get_property_document_notification_states()
  to authenticated;
revoke all on function public.set_property_document_notification_override(text, boolean)
  from public, anon;
grant execute on function public.set_property_document_notification_override(text, boolean)
  to authenticated;

create or replace function public.suppress_disabled_property_document_reminder()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  property_id_value text;
  override_value boolean;
  global_value boolean := true;
begin
  if new.kind is distinct from 'property_document_reminder' then
    return new;
  end if;

  property_id_value := new.payload ->> 'propertyId';

  select override_row.enabled
  into override_value
  from public.crm_property_document_notification_overrides as override_row
  where override_row.property_id = property_id_value;

  if override_value is not null then
    if override_value then return new; end if;
    return null;
  end if;

  select settings.property_document_notifications_enabled
  into global_value
  from public.crm_operational_settings as settings
  where settings.singleton;

  if not coalesce(global_value, true) then return null; end if;
  return new;
end;
$$;

revoke all on function public.suppress_disabled_property_document_reminder()
  from public, anon, authenticated;

comment on table public.crm_property_document_notification_overrides is
  'Ativacao individual dos tres avisos diarios dos nove documentos. A escolha individual prevalece sobre a configuracao geral.';

commit;
