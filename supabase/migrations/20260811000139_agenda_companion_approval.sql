begin;

alter table public.crm_agenda_entries
  add column if not exists companion_approval_status text not null default 'approved',
  add column if not exists companion_reason text,
  add column if not exists requested_companion_ids uuid[] not null default '{}'::uuid[],
  add column if not exists companion_decided_at timestamptz,
  add column if not exists companion_decided_by uuid references public.profiles(id);

alter table public.crm_agenda_entries drop constraint if exists crm_agenda_companion_approval_status_check;
alter table public.crm_agenda_entries add constraint crm_agenda_companion_approval_status_check
  check (companion_approval_status in ('approved','pending','rejected'));

create or replace function public.request_agenda_companion_approval(
  p_entry_id uuid, p_companion_user_ids uuid[], p_reason text
) returns text
language plpgsql security definer set search_path=pg_catalog,public as $$
declare entry public.crm_agenda_entries; requester_name text;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select * into entry from public.crm_agenda_entries where id=p_entry_id for update;
  if not found or entry.created_by<>auth.uid() then raise exception 'Demanda nao encontrada.'; end if;
  if coalesce(cardinality(p_companion_user_ids),0)=0 then return 'approved'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Informe o motivo do acompanhante.'; end if;
  if entry.target_user_id=any(p_companion_user_ids) then raise exception 'O acompanhante deve ser diferente do responsavel.'; end if;
  if exists(select 1 from unnest(p_companion_user_ids) x(id) left join public.profiles p on p.id=x.id where p.id is null) then
    raise exception 'Acompanhante invalido.';
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

create or replace function public.decide_agenda_companion_request(p_entry_id uuid,p_approved boolean)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare entry public.crm_agenda_entries;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson ou SoniaLima podem decidir este pedido.';
  end if;
  select * into entry from public.crm_agenda_entries where id=p_entry_id for update;
  if not found then raise exception 'Pedido nao encontrado.'; end if;
  if entry.companion_approval_status<>'pending' then return entry.companion_approval_status; end if;
  if not p_approved then
    update public.crm_agenda_entries set companion_approval_status='rejected',companion_decided_at=now(),companion_decided_by=auth.uid(),updated_at=now() where id=p_entry_id;
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    values(entry.created_by,'agenda_companion_rejected','Acompanhante nao autorizado',entry.companion_reason,'/agenda',jsonb_build_object('agendaId',p_entry_id));
    return 'rejected';
  end if;
  insert into public.crm_agenda_entry_participants(entry_id,user_id,added_by)
  select p_entry_id,id,auth.uid() from unnest(entry.requested_companion_ids) x(id) on conflict do nothing;
  update public.crm_agenda_entries set companion_approval_status='approved',companion_decided_at=now(),companion_decided_by=auth.uid(),updated_at=now() where id=p_entry_id;
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
  select recipient,'agenda_new_demand','Demanda com acompanhante autorizada',entry.observation,'/agenda',jsonb_build_object('agendaId',p_entry_id)
  from (select entry.target_user_id recipient union select unnest(entry.requested_companion_ids)) recipients;
  return 'approved';
end; $$;

revoke all on function public.request_agenda_companion_approval(uuid,uuid[],text), public.decide_agenda_companion_request(uuid,boolean) from public,anon;
grant execute on function public.request_agenda_companion_approval(uuid,uuid[],text), public.decide_agenda_companion_request(uuid,boolean) to authenticated;

commit;
