begin;

create or replace function public.create_lead_with_phones(
  p_name text,
  p_phone text,
  p_additional_phones text[],
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  created_lead record;
  current_profile public.profiles%rowtype;
  inserted_lead uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;

  select profile.* into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  if not found then
    raise exception 'Perfil nao encontrado.';
  end if;

  if public.is_allyson_admin() then
    if p_visit_scheduled_at is not null then
      select * into created_lead
      from public.create_scheduled_visit_lead(
        p_name, p_phone, p_email, p_property_interest, p_channel, p_notes,
        p_lead_type, p_desired_property_value, p_desired_location, null,
        p_visit_scheduled_at
      );
    else
      select * into created_lead
      from public.create_distributed_lead(
        p_name, p_phone, p_email, p_property_interest, p_stage, p_channel,
        p_notes, '', p_lead_type, p_desired_property_value, p_desired_location
      );
    end if;
  elsif current_profile.role = 'broker' then
    select * into created_lead
    from public.create_creator_owned_lead(
      p_name, p_phone, p_email, p_property_interest, p_stage, p_channel,
      p_notes, p_lead_type, p_desired_property_value, p_desired_location, null
    );
  elsif public.is_restricted_admin() then
    if p_lead_type not in ('Venda', 'Aluguel') then
      raise exception 'Tipo de lead invalido.';
    end if;
    if coalesce(p_desired_property_value, 0) <= 0 then
      raise exception 'Informe o valor medio do imovel desejado.';
    end if;
    if nullif(trim(p_desired_location), '') is null then
      raise exception 'Informe a localizacao desejada.';
    end if;

    insert into public.crm_leads (
      name, phone, email, property_interest, stage, channel, budget, notes,
      owner_id, created_by, lead_type, desired_property_value, desired_location,
      assignment_status, assignment_deadline_at
    )
    values (
      trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
      nullif(trim(p_property_interest), ''), 'Em atendimento',
      nullif(trim(p_channel), ''), 0, nullif(trim(p_notes), ''), auth.uid(),
      auth.uid(), p_lead_type, p_desired_property_value,
      trim(p_desired_location), 'accepted', null
    )
    returning crm_leads.id into inserted_lead;

    update public.crm_leads as saved_lead
    set stage = 'Em atendimento',
        assignment_status = 'accepted',
        assignment_deadline_at = null
    where saved_lead.id = inserted_lead;

    delete from public.lead_assignment_attempts as assignment_attempt
    where assignment_attempt.lead_id = inserted_lead;

    delete from public.crm_notification_outbox as notification
    where notification.kind = 'lead_assignment'
      and notification.payload ->> 'leadId' = inserted_lead::text;

    select
      inserted_lead,
      current_profile.id,
      coalesce(nullif(current_profile.full_name, ''), current_profile.email)
    into created_lead;
  else
    raise exception 'Perfil sem permissao para cadastrar lead.';
  end if;

  if created_lead.lead_id is null then
    raise exception 'Nao foi possivel cadastrar o lead.';
  end if;

  update public.crm_leads as saved_lead
  set additional_phones = coalesce(p_additional_phones, '{}'::text[])
  where saved_lead.id = created_lead.lead_id;

  return query
  select
    created_lead.lead_id,
    created_lead.assigned_owner_id,
    created_lead.assigned_owner_name;
end;
$$;

revoke all on function public.create_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) from public, anon;
grant execute on function public.create_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) to authenticated;

commit;
