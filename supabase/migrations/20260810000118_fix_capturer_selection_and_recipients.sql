-- Capturer selection follows the current property catalog. The legacy document
-- responsibility table is not complete and must not validate this operation.
create or replace function public.set_property_capturer(p_property_id text,p_broker_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare normalized_property_id text:=nullif(trim(p_property_id),''); selected_broker_name text;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem selecionar o corretor captador.';
  end if;
  if normalized_property_id is null or not exists(
    select 1 from public.crm_property_catalog catalog
    where catalog.external_id=normalized_property_id
  ) then raise exception 'Imovel nao encontrado no catalogo.'; end if;
  if p_broker_id is null then
    delete from public.crm_property_capturer_assignments assignment
    where assignment.property_id=normalized_property_id;
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

create or replace function public.set_property_capturer_selection(
  p_property_id text,p_selection text
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare normalized_property_id text:=nullif(trim(p_property_id),'');
  normalized_selection text:=nullif(trim(p_selection),''); selected_broker_id uuid;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem selecionar o corretor captador.';
  end if;
  if normalized_property_id is null or not exists(
    select 1 from public.crm_property_catalog catalog
    where catalog.external_id=normalized_property_id
  ) then raise exception 'Imovel nao encontrado no catalogo.'; end if;
  if normalized_selection is null then
    perform public.set_property_capturer(normalized_property_id,null);
    return;
  end if;
  if normalized_selection='__sonialima__' then
    insert into public.crm_property_capturer_assignments(
      property_id,broker_id,broker_name,is_institutional,set_by
    ) values(normalized_property_id,null,'SoniaLima',true,auth.uid())
    on conflict(property_id) do update set broker_id=null,broker_name='SoniaLima',
      is_institutional=true,set_by=excluded.set_by,updated_at=now();
    return;
  end if;
  begin selected_broker_id:=normalized_selection::uuid;
  exception when invalid_text_representation then raise exception 'Corretor captador invalido.';
  end;
  perform public.set_property_capturer(normalized_property_id,selected_broker_id);
end; $$;

-- Individual mode: selected capturer + accesscrm.
-- SoniaLima mode: every active CRM user. Reminders stop for that property as
-- soon as all nine required files are present.
create or replace function public.process_property_document_reminders()
returns integer language plpgsql security definer set search_path=public,storage as $$
declare property_row record; attached_count integer; pending_count integer;
  inserted_count integer; created_count integer:=0;
begin
  for property_row in select catalog.external_id,catalog.title,
    capturer.broker_id capturer_id,coalesce(capturer.is_institutional,false) is_institutional
    from public.crm_property_catalog catalog
    join public.crm_property_capturer_assignments capturer
      on capturer.property_id=catalog.external_id
    where lower(trim(coalesce(catalog.status,''))) not in ('vendido','vendida')
      and lower(trim(translate(coalesce(catalog.purpose,''),'çãáàâéêíóôõú','caaaaeeiooou')))
        not in ('locacao','aluguel')
  loop
    select count(distinct split_part(split_part(object.name,'/',2),'.',1)) into attached_count
    from storage.objects object where object.bucket_id='property-documents'
      and object.name like property_row.external_id||'/%'
      and split_part(split_part(object.name,'/',2),'.',1) in ('certidao-onus','certidao-iptu',
        'pgfn','tjdft','trf1-criminal','trf1-civil','trt10','tst','sefaz-df');
    pending_count:=9-coalesce(attached_count,0);
    if pending_count<=0 then continue; end if;
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select recipient.id,'property_document_reminder','Documentos pendentes do imovel',
      property_row.title||' possui '||pending_count||' documento(s) pendente(s). Anexe todos assim que possivel.',
      '/imoveis',jsonb_build_object('propertyId',property_row.external_id,
        'pendingDocuments',pending_count,'requiredDocuments',9,'documentSet','property')
    from (
      select profile.id from public.profiles profile
      where property_row.is_institutional and profile.role in ('admin','broker')
      union
      select property_row.capturer_id where not property_row.is_institutional
        and property_row.capturer_id is not null
      union
      select profile.id from public.profiles profile
      where not property_row.is_institutional
        and lower(trim(profile.email))='unassigned-institutional@example.invalid'
    ) recipient;
    get diagnostics inserted_count=row_count; created_count:=created_count+inserted_count;
  end loop;
  return created_count;
end; $$;

revoke all on function public.set_property_capturer(text,uuid) from public,anon;
grant execute on function public.set_property_capturer(text,uuid) to authenticated;
revoke all on function public.set_property_capturer_selection(text,text) from public,anon;
grant execute on function public.set_property_capturer_selection(text,text) to authenticated;
revoke all on function public.process_property_document_reminders()
  from public,anon,authenticated;
grant execute on function public.process_property_document_reminders() to service_role;
