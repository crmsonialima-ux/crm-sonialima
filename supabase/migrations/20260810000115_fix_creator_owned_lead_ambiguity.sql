-- Qualify lead_id references because the RETURNS TABLE output variable has the
-- same name as lead_assignment_attempts.lead_id in PL/pgSQL.
create or replace function public.create_creator_owned_lead(
  p_name text, p_phone text, p_email text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_lead_type text, p_desired_property_value numeric,
  p_desired_location text, p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  creator_profile public.profiles%rowtype;
  inserted_lead uuid;
  normalized_phone text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select profile.* into creator_profile
  from public.profiles as profile where profile.id=auth.uid();
  if not found then raise exception 'Perfil não encontrado.'; end if;
  if p_lead_type not in ('Venda','Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  if coalesce(p_desired_property_value,0)<=0 then
    raise exception 'Informe o valor médio do imóvel desejado.';
  end if;
  if nullif(trim(p_desired_location),'') is null then
    raise exception 'Informe a localização desejada.';
  end if;
  if p_stage='Visita agendada' and p_visit_scheduled_at is null then
    raise exception 'Informe a data e a hora da visita.';
  end if;

  normalized_phone:=regexp_replace(coalesce(p_phone,''),'\D','','g');
  if normalized_phone='' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists(
    select 1 from public.crm_leads as existing_lead
    where regexp_replace(coalesce(existing_lead.phone,''),'\D','','g')=normalized_phone
  ) then raise exception 'Já existe um lead cadastrado com este telefone.'; end if;

  insert into public.crm_leads(
    name,phone,email,property_interest,stage,channel,budget,notes,owner_id,created_by,
    lead_type,desired_property_value,desired_location,visit_scheduled_at,
    assignment_status,assignment_deadline_at
  ) values(
    trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_property_interest),''),
    p_stage,nullif(trim(p_channel),''),0,nullif(trim(p_notes),''),auth.uid(),auth.uid(),
    p_lead_type,p_desired_property_value,trim(p_desired_location),p_visit_scheduled_at,
    'accepted',null
  ) returning crm_leads.id into inserted_lead;

  update public.crm_leads as created_lead
  set owner_id=auth.uid(),assignment_status='accepted',assignment_deadline_at=null
  where created_lead.id=inserted_lead;

  delete from public.lead_assignment_attempts as assignment_attempt
  where assignment_attempt.lead_id=inserted_lead;

  delete from public.crm_notification_outbox as notification
  where notification.kind='lead_assignment'
    and notification.payload->>'leadId'=inserted_lead::text;

  return query select inserted_lead,creator_profile.id,
    coalesce(nullif(creator_profile.full_name,''),creator_profile.email);
end;
$$;

revoke all on function public.create_creator_owned_lead(
  text,text,text,text,text,text,text,text,numeric,text,timestamptz
) from public,anon;
grant execute on function public.create_creator_owned_lead(
  text,text,text,text,text,text,text,text,numeric,text,timestamptz
) to authenticated;
