-- Individual capturer selection must leave institutional mode.
create or replace function public.set_property_capturer(p_property_id text,p_broker_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare normalized_property_id text:=nullif(trim(p_property_id),''); selected_broker_name text;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem selecionar o corretor captador.';
  end if;
  if normalized_property_id is null or not exists(
    select 1 from public.crm_property_document_responsibilities
    where external_id=normalized_property_id
  ) then raise exception 'Imovel invalido.'; end if;
  if p_broker_id is null then
    delete from public.crm_property_capturer_assignments where property_id=normalized_property_id;
    return;
  end if;
  select coalesce(nullif(trim(profile.full_name),''),profile.email) into selected_broker_name
  from public.profiles profile where profile.id=p_broker_id and profile.role='broker';
  if selected_broker_name is null then raise exception 'Corretor captador invalido.'; end if;
  insert into public.crm_property_capturer_assignments(
    property_id,broker_id,broker_name,is_institutional,set_by
  ) values(normalized_property_id,p_broker_id,selected_broker_name,false,auth.uid())
  on conflict(property_id) do update set broker_id=excluded.broker_id,
    broker_name=excluded.broker_name,is_institutional=false,
    set_by=excluded.set_by,updated_at=now();
end; $$;

-- Broker-created leads always start owned by their creator and in attendance.
create or replace function public.create_creator_owned_lead(
  p_name text,p_phone text,p_email text,p_property_interest text,p_stage text,
  p_channel text,p_notes text,p_lead_type text,p_desired_property_value numeric,
  p_desired_location text,p_visit_scheduled_at timestamptz default null
)
returns table(lead_id uuid,assigned_owner_id uuid,assigned_owner_name text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare creator_profile public.profiles%rowtype; inserted_lead uuid; normalized_phone text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select profile.* into creator_profile from public.profiles profile where profile.id=auth.uid();
  if not found or creator_profile.role<>'broker' then raise exception 'Perfil de corretor não encontrado.'; end if;
  if p_lead_type not in ('Venda','Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  if coalesce(p_desired_property_value,0)<=0 then raise exception 'Informe o valor médio do imóvel desejado.'; end if;
  if nullif(trim(p_desired_location),'') is null then raise exception 'Informe a localização desejada.'; end if;
  normalized_phone:=regexp_replace(coalesce(p_phone,''),'\D','','g');
  if normalized_phone='' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists(select 1 from public.crm_leads existing_lead
    where regexp_replace(coalesce(existing_lead.phone,''),'\D','','g')=normalized_phone)
  then raise exception 'Já existe um lead cadastrado com este telefone.'; end if;
  insert into public.crm_leads(name,phone,email,property_interest,stage,channel,budget,notes,
    owner_id,created_by,lead_type,desired_property_value,desired_location,visit_scheduled_at,
    assignment_status,assignment_deadline_at)
  values(trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),
    nullif(trim(p_property_interest),''),'Em atendimento',nullif(trim(p_channel),''),0,
    nullif(trim(p_notes),''),auth.uid(),auth.uid(),p_lead_type,p_desired_property_value,
    trim(p_desired_location),null,'accepted',null)
  returning crm_leads.id into inserted_lead;
  update public.crm_leads created_lead set owner_id=auth.uid(),stage='Em atendimento',
    visit_scheduled_at=null,assignment_status='accepted',assignment_deadline_at=null
    where created_lead.id=inserted_lead;
  delete from public.lead_assignment_attempts assignment_attempt
    where assignment_attempt.lead_id=inserted_lead;
  delete from public.crm_notification_outbox notification
    where notification.kind='lead_assignment' and notification.payload->>'leadId'=inserted_lead::text;
  return query select inserted_lead,creator_profile.id,
    coalesce(nullif(creator_profile.full_name,''),creator_profile.email);
end; $$;

-- Rental-only properties do not require the nine sale documents or reminders.
create or replace function public.process_property_document_reminders()
returns integer language plpgsql security definer set search_path=public,storage as $$
declare property_row record; attached_count integer; pending_count integer;
  inserted_count integer; created_count integer:=0;
begin
  for property_row in select catalog.external_id,catalog.title,
    capturer.broker_id capturer_id,coalesce(capturer.is_institutional,false) is_institutional
    from public.crm_property_catalog catalog
    left join public.crm_property_capturer_assignments capturer on capturer.property_id=catalog.external_id
    where lower(trim(coalesce(catalog.status,''))) not in ('vendido','vendida')
      and lower(trim(translate(coalesce(catalog.purpose,''),'çãáàâéêíóôõú','caaaaeeiooou')))
        not in ('locacao','aluguel')
  loop
    select count(distinct split_part(split_part(name,'/',2),'.',1)) into attached_count
    from storage.objects where bucket_id='property-documents'
      and name like property_row.external_id||'/%'
      and split_part(split_part(name,'/',2),'.',1) in ('certidao-onus','certidao-iptu','pgfn',
        'tjdft','trf1-criminal','trf1-civil','trt10','tst','sefaz-df');
    pending_count:=9-coalesce(attached_count,0); if pending_count<=0 then continue; end if;
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select recipient_id,'property_document_reminder','Documentos pendentes do imovel',
      property_row.title||' possui '||pending_count||' documento(s) pendente(s). Anexe todos assim que possivel.',
      '/imoveis',jsonb_build_object('propertyId',property_row.external_id,'pendingDocuments',pending_count,
        'requiredDocuments',9,'documentSet','property') from (
      select access.broker_id recipient_id from public.crm_property_broker_access access
      join public.profiles profile on profile.id=access.broker_id and profile.role='broker'
      where property_row.is_institutional and access.property_id=property_row.external_id
      union select property_row.capturer_id where not property_row.is_institutional
        and property_row.capturer_id is not null
      union select profile.id from public.profiles profile
        where lower(trim(profile.email))='unassigned-institutional@example.invalid') recipients;
    get diagnostics inserted_count=row_count; created_count:=created_count+inserted_count;
  end loop; return created_count;
end; $$;

delete from public.crm_notification_outbox notification using public.crm_property_catalog catalog
where notification.kind='property_document_reminder'
  and notification.payload->>'propertyId'=catalog.external_id
  and lower(trim(translate(coalesce(catalog.purpose,''),'çãáàâéêíóôõú','caaaaeeiooou')))
    in ('locacao','aluguel');

revoke all on function public.process_property_document_reminders() from public,anon,authenticated;
grant execute on function public.process_property_document_reminders() to service_role;
