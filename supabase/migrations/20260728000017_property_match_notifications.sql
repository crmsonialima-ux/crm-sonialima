-- Preferências de imóvel do lead e alertas para imóveis novos compatíveis.
alter table public.crm_leads
  add column if not exists desired_property_value numeric,
  add column if not exists desired_location text,
  add column if not exists not_interested_at timestamptz;

create table if not exists public.crm_property_catalog (
  external_id text primary key,
  title text not null,
  address text,
  neighborhood text,
  city text,
  purpose text,
  value numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.crm_property_match_notifications (
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  property_external_id text not null references public.crm_property_catalog(external_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (lead_id, property_external_id)
);

alter table public.crm_property_catalog enable row level security;
alter table public.crm_property_match_notifications enable row level security;
grant select on public.crm_property_catalog, public.crm_property_match_notifications to authenticated;
create policy "Authenticated users read property catalog" on public.crm_property_catalog for select using (auth.uid() is not null);
create policy "Users read own property matches" on public.crm_property_match_notifications for select
using (public.is_admin() or exists (select 1 from public.crm_leads where id = lead_id and owner_id = auth.uid()));

create or replace function public.set_not_interested_timestamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'Não teve interesse' and old.stage is distinct from 'Não teve interesse' then
    new.not_interested_at = now();
  elsif old.stage = 'Não teve interesse' and new.stage is distinct from 'Não teve interesse' then
    new.not_interested_at = null;
  end if;
  return new;
end;
$$;
drop trigger if exists crm_leads_set_not_interested_timestamp on public.crm_leads;
create trigger crm_leads_set_not_interested_timestamp
before update of stage on public.crm_leads
for each row execute procedure public.set_not_interested_timestamp();

create or replace function public.create_distributed_lead(
  p_name text, p_phone text, p_email text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_external_id text, p_lead_type text,
  p_desired_property_value numeric, p_desired_location text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path = public as $$
declare next_broker record; next_position integer; inserted_lead uuid; normalized_phone text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_lead_type not in ('Venda', 'Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  if coalesce(p_desired_property_value, 0) <= 0 then raise exception 'Informe o valor médio do imóvel desejado.'; end if;
  if nullif(trim(p_desired_location), '') is null then raise exception 'Informe a localização desejada.'; end if;
  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (select 1 from public.crm_leads where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;
  select q.broker_id, p.full_name, p.email into next_broker
  from public.lead_distribution_queue q join public.profiles p on p.id = q.broker_id
  where q.lead_type = p_lead_type and p.role = 'broker' and not coalesce(p.lead_distribution_blocked, false)
  order by q.position limit 1 for update of q skip locked;
  if next_broker.broker_id is null then raise exception 'Não há corretores disponíveis na fila de %.', p_lead_type; end if;
  select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = p_lead_type;
  update public.lead_distribution_queue set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;
  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by,
    external_id, lead_type, desired_property_value, desired_location
  ) values (
    p_name, nullif(p_phone, ''), nullif(p_email, ''), nullif(p_property_interest, ''), p_stage,
    nullif(p_channel, ''), 0, nullif(p_notes, ''), next_broker.broker_id, auth.uid(),
    nullif(p_external_id, ''), p_lead_type, p_desired_property_value, trim(p_desired_location)
  ) returning id into inserted_lead;
  return query select inserted_lead, next_broker.broker_id, coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

create or replace function public.sync_property_catalog(p_properties jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare item jsonb; property_id text; was_known boolean; is_initial_sync boolean; lead_row record; matched boolean; synced integer := 0;
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem sincronizar imóveis.'; end if;
  select not exists (select 1 from public.crm_property_catalog) into is_initial_sync;
  for item in select value from jsonb_array_elements(coalesce(p_properties, '[]'::jsonb)) loop
    property_id := nullif(trim(coalesce(item ->> 'id', item ->> 'code', item ->> 'title')), '');
    if property_id is null then continue; end if;
    select exists (select 1 from public.crm_property_catalog where external_id = property_id) into was_known;
    insert into public.crm_property_catalog (external_id, title, address, neighborhood, city, purpose, value)
    values (
      property_id, coalesce(nullif(item ->> 'title', ''), property_id), nullif(item ->> 'address', ''),
      nullif(item ->> 'neighborhood', ''), nullif(item ->> 'city', ''), nullif(item ->> 'purpose', ''),
      nullif(item ->> 'value', '')::numeric
    ) on conflict (external_id) do update set
      title = excluded.title, address = excluded.address, neighborhood = excluded.neighborhood,
      city = excluded.city, purpose = excluded.purpose, value = excluded.value, updated_at = now();
    synced := synced + 1;

    if was_known or is_initial_sync then continue; end if;
    for lead_row in
      select id, owner_id, name
      from public.crm_leads
      where stage = 'Não teve interesse'
        and not_interested_at is not null
        and not_interested_at <= now()
        and desired_property_value is not null
        and desired_location is not null
        and (nullif(item ->> 'value', '')::numeric <= desired_property_value + 50000)
        and lower(concat_ws(' ', item ->> 'address', item ->> 'neighborhood', item ->> 'city', item ->> 'title'))
          like '%' || lower(desired_location) || '%'
    loop
      insert into public.crm_property_match_notifications (lead_id, property_external_id)
      values (lead_row.id, property_id) on conflict do nothing returning true into matched;
      if matched then
        insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
        values (
          lead_row.owner_id, 'property_match', 'Imóvel compatível encontrado',
          'O imóvel ' || coalesce(item ->> 'title', property_id) || ' atende ao lead ' || lead_row.name || '.',
          '/imoveis', jsonb_build_object('leadId', lead_row.id, 'propertyId', property_id, 'name', lead_row.name)
        );
      end if;
      matched := false;
    end loop;
  end loop;
  return synced;
end;
$$;

grant execute on function public.create_distributed_lead(text, text, text, text, text, text, text, text, text, numeric, text) to authenticated;
grant execute on function public.sync_property_catalog(jsonb) to authenticated;
