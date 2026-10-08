begin;

-- Keep every post-sale call visible in AcessoCRM's agenda. A simultaneous
-- completion can create many follow-ups, so reserve one minute per buyer.
create or replace function public.normalize_crm_sale_followup_slot()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  candidate timestamptz;
begin
  if new.source_kind <> 'sale_followup' then return new; end if;

  perform pg_advisory_xact_lock(
    hashtext('crm-sale-followup-slot:' || new.target_user_id::text || ':' ||
      to_char(new.scheduled_at at time zone 'America/Sao_Paulo','YYYY-MM-DD'))
  );
  candidate:=date_trunc('minute',new.scheduled_at);
  while exists (
    select 1 from public.crm_agenda_entries entry
    where entry.target_user_id=new.target_user_id
      and entry.scheduled_at=candidate
      and entry.id is distinct from new.id
  ) loop
    candidate:=candidate+interval '1 minute';
  end loop;
  new.scheduled_at:=candidate;
  return new;
end;
$$;

drop trigger if exists crm_agenda_entries_stagger_sale_followups on public.crm_agenda_entries;
create trigger crm_agenda_entries_stagger_sale_followups
before insert or update of scheduled_at,target_user_id on public.crm_agenda_entries
for each row execute function public.normalize_crm_sale_followup_slot();

create or replace function public.notify_crm_sale_followup_created()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  if new.source_kind='sale_followup' then
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at)
    values (
      new.target_user_id,'sale_followup','Pós-venda programado',new.observation,'/agenda',
      jsonb_build_object('agendaId',new.id,'saleId',new.source_sale_id),new.scheduled_at
    );
  end if;
  return new;
end;
$$;

drop trigger if exists crm_agenda_entries_notify_sale_followup on public.crm_agenda_entries;
create trigger crm_agenda_entries_notify_sale_followup
after insert on public.crm_agenda_entries
for each row execute function public.notify_crm_sale_followup_created();

-- Backfill makes the rule reliable even if the last document was saved while
-- the scheduler was unavailable. It is safe to run repeatedly.
create or replace function public.process_crm_sale_followups()
returns integer
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  aftercare_id uuid;
  transfer record;
  sale_row public.crm_sales%rowtype;
  created_count integer:=0;
begin
  select id into aftercare_id from public.profiles
  where lower(trim(email))='unassigned-institutional@example.invalid' limit 1;
  if aftercare_id is null then return 0; end if;

  for transfer in
    select entry.source_sale_id,entry.sale_documents_completed_at,entry.created_by
    from public.crm_agenda_entries entry
    where entry.source_kind='sale_transfer'
      and entry.sale_documents_completed_at is not null
      and not exists (
        select 1 from public.crm_agenda_entries followup
        where followup.source_sale_id=entry.source_sale_id and followup.sale_task_kind='followup'
      )
    for update of entry skip locked
  loop
    select * into sale_row from public.crm_sales where id=transfer.source_sale_id;
    if not found then continue; end if;
    insert into public.crm_agenda_entries(
      category,scheduled_at,observation,target_user_id,created_by,
      source_kind,source_sale_id,sale_task_kind
    ) values (
      'observacao',transfer.sale_documents_completed_at+interval '7 days',
      'Pos-venda: ligar para '||sale_row.buyer_name||' ('||coalesce(sale_row.buyer_phone,'sem telefone')||')'
        || E'\nImovel: '||sale_row.property_address,
      aftercare_id,transfer.created_by,'sale_followup',sale_row.id,'followup'
    ) on conflict (source_sale_id,sale_task_kind) where source_sale_id is not null do nothing;
    if found then created_count:=created_count+1; end if;
  end loop;
  return created_count;
end;
$$;

revoke all on function public.process_crm_sale_followups() from public,anon,authenticated;
grant execute on function public.process_crm_sale_followups() to service_role;
select cron.schedule('crm-sale-followups','* * * * *','select public.process_crm_sale_followups();');
select public.process_crm_sale_followups();

commit;
