alter table public.crm_leads
  add column if not exists additional_phones text[] not null default '{}'::text[];

create or replace function public.validate_crm_lead_phones()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare normalized_phones text[]; phone_value text; normalized_phone text;
begin
  new.additional_phones:=coalesce(array(
    select trim(value) from unnest(coalesce(new.additional_phones,'{}'::text[])) value
    where nullif(trim(value),'') is not null
  ),'{}'::text[]);
  normalized_phones:='{}'::text[];
  foreach phone_value in array array_prepend(new.phone,new.additional_phones) loop
    normalized_phone:=public.normalize_crm_phone_identity(phone_value);
    if normalized_phone is null then continue; end if;
    if length(normalized_phone) not in (10,11) then
      raise exception 'Informe telefones com DDD e 10 ou 11 digitos.';
    end if;
    if normalized_phone=any(normalized_phones) then
      raise exception 'O mesmo telefone foi informado mais de uma vez.';
    end if;
    perform pg_advisory_xact_lock(hashtext('lead-phone:'||normalized_phone));
    normalized_phones:=array_append(normalized_phones,normalized_phone);
  end loop;
  if cardinality(normalized_phones)=0 then raise exception 'Telefone e obrigatorio.'; end if;
  if exists(
    select 1 from public.crm_leads existing_lead
    cross join lateral unnest(array_prepend(existing_lead.phone,
      coalesce(existing_lead.additional_phones,'{}'::text[]))) existing_phone
    where existing_lead.id is distinct from new.id
      and public.normalize_crm_phone_identity(existing_phone)=any(normalized_phones)
  ) then raise exception 'Ja existe um lead cadastrado com um destes telefones.'; end if;
  return new;
end; $$;

drop trigger if exists validate_crm_lead_phones on public.crm_leads;
create trigger validate_crm_lead_phones before insert or update of phone,additional_phones
on public.crm_leads for each row execute function public.validate_crm_lead_phones();

create or replace function public.find_duplicate_lead_phones(
  p_phones text[],p_exclude_lead_id uuid default null
)
returns text[] language sql stable security definer set search_path=pg_catalog,public as $$
  with requested as (
    select distinct public.normalize_crm_phone_identity(requested_phone.value) identity
    from unnest(coalesce(p_phones,'{}'::text[])) requested_phone(value)
    where public.normalize_crm_phone_identity(requested_phone.value) is not null
  ), existing as (
    select distinct public.normalize_crm_phone_identity(existing_phone.value) identity
    from public.crm_leads lead
    cross join lateral unnest(array_prepend(lead.phone,
      coalesce(lead.additional_phones,'{}'::text[]))) existing_phone(value)
    where lead.id is distinct from p_exclude_lead_id
  )
  select coalesce(array_agg(requested.identity order by requested.identity),'{}'::text[])
  from requested join existing using(identity);
$$;

create or replace function public.create_lead_with_phones(
  p_name text,p_phone text,p_additional_phones text[],p_email text,
  p_property_interest text,p_stage text,p_channel text,p_notes text,p_lead_type text,
  p_desired_property_value numeric,p_desired_location text,
  p_visit_scheduled_at timestamptz default null
)
returns table(lead_id uuid,assigned_owner_id uuid,assigned_owner_name text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare created_lead record; current_profile public.profiles%rowtype; inserted_lead uuid;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select profile.* into current_profile from public.profiles profile where profile.id=auth.uid();
  if not found then raise exception 'Perfil nao encontrado.'; end if;
  if public.is_allyson_admin() then
    if p_visit_scheduled_at is not null then
      select * into created_lead from public.create_scheduled_visit_lead(
        p_name,p_phone,p_email,p_property_interest,p_channel,p_notes,p_lead_type,
        p_desired_property_value,p_desired_location,null,p_visit_scheduled_at);
    else
      select * into created_lead from public.create_distributed_lead(
        p_name,p_phone,p_email,p_property_interest,p_stage,p_channel,p_notes,'',p_lead_type,
        p_desired_property_value,p_desired_location);
    end if;
  elsif current_profile.role='broker' then
    select * into created_lead from public.create_creator_owned_lead(
      p_name,p_phone,p_email,p_property_interest,p_stage,p_channel,p_notes,p_lead_type,
      p_desired_property_value,p_desired_location,null);
  elsif public.is_restricted_admin() then
    if p_lead_type not in ('Venda','Aluguel') then raise exception 'Tipo de lead invalido.'; end if;
    if coalesce(p_desired_property_value,0)<=0 then raise exception 'Informe o valor medio do imovel desejado.'; end if;
    if nullif(trim(p_desired_location),'') is null then raise exception 'Informe a localizacao desejada.'; end if;
    insert into public.crm_leads(name,phone,email,property_interest,stage,channel,budget,notes,
      owner_id,created_by,lead_type,desired_property_value,desired_location,
      assignment_status,assignment_deadline_at)
    values(trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),
      nullif(trim(p_property_interest),''),'Em atendimento',nullif(trim(p_channel),''),0,
      nullif(trim(p_notes),''),auth.uid(),auth.uid(),p_lead_type,p_desired_property_value,
      trim(p_desired_location),'accepted',null) returning id into inserted_lead;
    update public.crm_leads set stage='Em atendimento',assignment_status='accepted',
      assignment_deadline_at=null where id=inserted_lead;
    delete from public.lead_assignment_attempts where lead_id=inserted_lead;
    delete from public.crm_notification_outbox where kind='lead_assignment'
      and payload->>'leadId'=inserted_lead::text;
    select inserted_lead as lead_id,current_profile.id as assigned_owner_id,
      coalesce(nullif(current_profile.full_name,''),current_profile.email) as assigned_owner_name
    into created_lead;
  else raise exception 'Perfil sem permissao para cadastrar lead.';
  end if;
  if created_lead.lead_id is null then raise exception 'Nao foi possivel cadastrar o lead.'; end if;
  update public.crm_leads set additional_phones=coalesce(p_additional_phones,'{}'::text[])
  where id=created_lead.lead_id;
  return query select created_lead.lead_id,created_lead.assigned_owner_id,
    created_lead.assigned_owner_name;
end; $$;

revoke all on function public.create_lead_with_phones(text,text,text[],text,text,text,text,text,text,numeric,text,timestamptz)
  from public,anon;
grant execute on function public.create_lead_with_phones(text,text,text[],text,text,text,text,text,text,numeric,text,timestamptz)
  to authenticated;
revoke all on function public.find_duplicate_lead_phones(text[],uuid) from public,anon;
grant execute on function public.find_duplicate_lead_phones(text[],uuid) to authenticated;
