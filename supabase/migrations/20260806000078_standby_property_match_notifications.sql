-- Mantem leads em Standby e Nao teve interesse sob monitoramento de novos imoveis.
-- A coluna historica not_interested_at passa a representar o inicio desse monitoramento.
create or replace function public.set_not_interested_timestamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.stage in ('Standby', 'Não teve interesse')
     and (old.stage is null or old.stage not in ('Standby', 'Não teve interesse')) then
    new.not_interested_at = now();
  elsif new.stage not in ('Standby', 'Não teve interesse')
        and old.stage in ('Standby', 'Não teve interesse') then
    new.not_interested_at = null;
  end if;
  return new;
end;
$$;

-- Leads que ja estavam em Standby antes desta correcao tambem devem ser monitorados.
update public.crm_leads
set not_interested_at = coalesce(not_interested_at, updated_at, now())
where stage in ('Standby', 'Não teve interesse')
  and not_interested_at is null;

create extension if not exists pg_trgm with schema extensions;

alter table public.crm_property_catalog
  add column if not exists match_checked_at timestamptz;

-- Imoveis anteriores ao inicio do monitoramento nao devem gerar alertas retroativos.
update public.crm_property_catalog as property
set match_checked_at = now()
where property.match_checked_at is null
  and not exists (
    select 1
    from public.crm_leads as lead
    where lead.stage in ('Standby', 'Não teve interesse')
      and lead.not_interested_at is not null
      and lead.not_interested_at <= property.created_at
  );

create or replace function public.crm_normalize_property_match_text(p_value text)
returns text
language sql
immutable
parallel safe
set search_path = public
as $$
  select trim(
    regexp_replace(
      translate(
        lower(coalesce(p_value, '')),
        'áàãâäéèêëíìîïóòõôöúùûüç',
        'aaaaaeeeeiiiiooooouuuuc'
      ),
      '[^a-z0-9]+',
      ' ',
      'g'
    )
  );
$$;

create or replace function public.crm_evaluate_property_matches(p_property_id text)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  property_row public.crm_property_catalog%rowtype;
  lead_row record;
  desired_region text;
  property_search_text text;
  normalized_neighborhood text;
  matched boolean;
  notified integer := 0;
begin
  select * into property_row
  from public.crm_property_catalog
  where external_id = p_property_id
  for update;

  if not found or property_row.match_checked_at is not null then
    return 0;
  end if;

  property_search_text := public.crm_normalize_property_match_text(
    concat_ws(
      ' ',
      property_row.address,
      property_row.neighborhood,
      property_row.city,
      property_row.title
    )
  );
  normalized_neighborhood := public.crm_normalize_property_match_text(property_row.neighborhood);

  for lead_row in
    select lead.id, lead.owner_id, lead.name, lead.desired_location
    from public.crm_leads as lead
    where lead.stage in ('Standby', 'Não teve interesse')
      and lead.not_interested_at is not null
      and lead.not_interested_at <= property_row.created_at
      and lead.desired_property_value is not null
      and property_row.value is not null
      and property_row.value <= lead.desired_property_value + 50000
  loop
    desired_region := public.crm_normalize_property_match_text(
      split_part(lead_row.desired_location, ',', 1)
    );

    if desired_region = '' or not (
      position(desired_region in property_search_text) > 0
      or similarity(desired_region, normalized_neighborhood) >= 0.50
      or word_similarity(desired_region, property_search_text) >= 0.50
    ) then
      continue;
    end if;

    matched := false;
    insert into public.crm_property_match_notifications (lead_id, property_external_id)
    values (lead_row.id, property_row.external_id)
    on conflict do nothing
    returning true into matched;

    if matched then
      insert into public.crm_notification_outbox (
        recipient_id,
        kind,
        title,
        body,
        url,
        payload
      )
      values (
        lead_row.owner_id,
        'property_match',
        'Imóvel compatível encontrado',
        'O imóvel ' || property_row.title || ' pode atender ao lead ' || lead_row.name || '.',
        '/imoveis',
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
          'desiredLocation', lead_row.desired_location,
          'propertyNeighborhood', property_row.neighborhood
        )
      );
      notified := notified + 1;
    end if;
  end loop;

  update public.crm_property_catalog
  set match_checked_at = now()
  where external_id = property_row.external_id;

  return notified;
end;
$$;

create or replace function public.sync_property_catalog(p_properties jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  property_id text;
  is_initial_sync boolean;
  property_match_checked_at timestamptz;
  synced integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem sincronizar imóveis.';
  end if;

  select not exists (select 1 from public.crm_property_catalog) into is_initial_sync;

  for item in
    select value from jsonb_array_elements(coalesce(p_properties, '[]'::jsonb))
  loop
    property_id := nullif(trim(coalesce(item ->> 'id', item ->> 'code', item ->> 'title')), '');
    if property_id is null then
      continue;
    end if;

    insert into public.crm_property_catalog as current_property (
      external_id,
      title,
      address,
      neighborhood,
      city,
      purpose,
      value
    )
    values (
      property_id,
      coalesce(nullif(item ->> 'title', ''), property_id),
      nullif(item ->> 'address', ''),
      nullif(item ->> 'neighborhood', ''),
      nullif(item ->> 'city', ''),
      nullif(item ->> 'purpose', ''),
      nullif(item ->> 'value', '')::numeric
    )
    on conflict (external_id) do update set
      match_checked_at = case
        when (
          current_property.title,
          current_property.address,
          current_property.neighborhood,
          current_property.city,
          current_property.purpose,
          current_property.value
        ) is distinct from (
          excluded.title,
          excluded.address,
          excluded.neighborhood,
          excluded.city,
          excluded.purpose,
          excluded.value
        ) then null
        else current_property.match_checked_at
      end,
      title = excluded.title,
      address = excluded.address,
      neighborhood = excluded.neighborhood,
      city = excluded.city,
      purpose = excluded.purpose,
      value = excluded.value,
      updated_at = now()
    returning match_checked_at into property_match_checked_at;

    synced := synced + 1;

    -- O primeiro carregamento apenas forma o catalogo e nao dispara alertas antigos.
    if is_initial_sync then
      update public.crm_property_catalog
      set match_checked_at = coalesce(match_checked_at, now())
      where external_id = property_id;
    elsif property_match_checked_at is null then
      perform public.crm_evaluate_property_matches(property_id);
    end if;
  end loop;

  return synced;
end;
$$;

revoke all on function public.crm_normalize_property_match_text(text) from public, anon;
grant execute on function public.crm_normalize_property_match_text(text) to authenticated, service_role;
revoke all on function public.crm_evaluate_property_matches(text) from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;
grant execute on function public.sync_property_catalog(jsonb) to authenticated;

-- Reavalia somente imoveis ainda nao processados e cadastrados depois do inicio da espera.
select public.crm_evaluate_property_matches(property.external_id)
from public.crm_property_catalog as property
where property.match_checked_at is null;
