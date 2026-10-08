begin;

create or replace function public.request_agenda_companion_approval(
  p_entry_id uuid, p_companion_user_ids uuid[], p_reason text
) returns text
language plpgsql security definer set search_path=pg_catalog,public as $$
declare entry public.crm_agenda_entries; requester_name text;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select * into entry from public.crm_agenda_entries where id=p_entry_id for update;
  
  if not found or (entry.created_by <> auth.uid() and entry.target_user_id <> auth.uid() and not public.is_allyson_admin()) then 
    raise exception 'Demanda nao encontrada ou sem permissao.'; 
  end if;

  if not public.is_allyson_admin() and entry.source_kind = 'lead_visit' and entry.scheduled_at <= now() then
    raise exception 'Apenas Allyson pode alterar acompanhantes depois que o horario da visita ja passou.';
  end if;

  if coalesce(cardinality(p_companion_user_ids),0)=0 then 
    if public.is_allyson_admin() or entry.companion_approval_status = 'pending' then
      delete from public.crm_agenda_entry_participants where entry_id = p_entry_id;
      update public.crm_agenda_entries set companion_approval_status='approved', requested_companion_ids='{}'::uuid[], companion_reason=null where id=p_entry_id;
    end if;
    return 'approved'; 
  end if;
  
  if nullif(trim(p_reason),'') is null and not public.is_allyson_admin() then raise exception 'Informe o motivo do acompanhante.'; end if;
  if entry.target_user_id=any(p_companion_user_ids) then raise exception 'O acompanhante deve ser diferente do responsavel.'; end if;
  if exists(select 1 from unnest(p_companion_user_ids) x(id) left join public.profiles p on p.id=x.id where p.id is null) then
    raise exception 'Acompanhante invalido.';
  end if;

  if public.is_allyson_admin() then
    delete from public.crm_agenda_entry_participants where entry_id = p_entry_id;
    insert into public.crm_agenda_entry_participants(entry_id,user_id,added_by)
    select p_entry_id,id,auth.uid() from unnest(p_companion_user_ids) x(id) on conflict do nothing;
    
    update public.crm_agenda_entries set companion_approval_status='approved', companion_reason=trim(p_reason),
      requested_companion_ids=array(select distinct unnest(p_companion_user_ids)), updated_at=now(),
      companion_decided_at=now(), companion_decided_by=auth.uid() where id=p_entry_id;
    return 'approved';
  end if;

  select coalesce(nullif(trim(full_name),''),email) into requester_name from public.profiles where id=auth.uid();
  update public.crm_agenda_entries set companion_approval_status='pending', companion_reason=trim(p_reason),
    requested_companion_ids=array(select distinct unnest(p_companion_user_ids)), updated_at=now() where id=p_entry_id;
  
  delete from public.crm_notification_outbox where payload->>'agendaId'=p_entry_id::text and delivered_at is null;
  
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
  select p.id,'agenda_companion_approval','Autorizar acompanhante na agenda',
    requester_name||' solicitou acompanhante. Motivo: '||trim(p_reason),'/agenda',
    jsonb_build_object('agendaId',p_entry_id,'reason',trim(p_reason),'decisionStatus','pending')
  from public.profiles p where lower(trim(p.email)) in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid');
  return 'pending';
end; $$;

commit;
