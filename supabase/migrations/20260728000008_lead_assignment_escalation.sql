-- Esteira finita de atendimento: 15 min no primeiro corretor e 4 min nos demais.
alter table public.crm_leads
  add column if not exists assignment_status text not null default 'accepted'
    check (assignment_status in ('pending', 'accepted', 'exhausted')),
  add column if not exists assignment_deadline_at timestamptz;

create table if not exists public.lead_assignment_attempts (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  broker_id uuid not null references public.profiles(id) on delete cascade,
  attempt_number integer not null,
  notified_at timestamptz not null default now(),
  deadline_at timestamptz not null,
  accepted_at timestamptz,
  expired_at timestamptz,
  unique (lead_id, broker_id)
);

create table if not exists public.crm_notification_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  url text not null default '/leads',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists lead_assignment_attempts_pending_idx
  on public.lead_assignment_attempts(lead_id, deadline_at) where accepted_at is null and expired_at is null;
create index if not exists crm_leads_assignment_deadline_idx
  on public.crm_leads(assignment_deadline_at) where assignment_status = 'pending';
create index if not exists crm_notification_outbox_pending_idx
  on public.crm_notification_outbox(created_at) where delivered_at is null;

alter table public.lead_assignment_attempts enable row level security;
alter table public.crm_notification_outbox enable row level security;
alter table public.push_subscriptions enable row level security;
grant select on public.lead_assignment_attempts, public.crm_notification_outbox to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

create policy "Users read attempts for their leads"
  on public.lead_assignment_attempts for select
  using (
    public.is_admin() or exists (
      select 1 from public.crm_leads
      where crm_leads.id = lead_assignment_attempts.lead_id and crm_leads.owner_id = auth.uid()
    )
  );
create policy "Users read their notifications"
  on public.crm_notification_outbox for select using (recipient_id = auth.uid());
create policy "Users manage their own push subscriptions"
  on public.push_subscriptions for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.start_lead_assignment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.crm_leads
  set assignment_status = 'pending', assignment_deadline_at = now() + interval '15 minutes', stage = 'Aguardando atendimento'
  where id = new.id;
  insert into public.lead_assignment_attempts (lead_id, broker_id, attempt_number, deadline_at)
  values (new.id, new.owner_id, 1, now() + interval '15 minutes');
  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    new.owner_id, 'lead_assignment', 'Novo lead aguardando atendimento',
    'Você tem 15 minutos para iniciar o atendimento de ' || new.name || '.', '/leads',
    jsonb_build_object('leadId', new.id, 'phone', new.phone, 'name', new.name)
  );
  return new;
end;
$$;

drop trigger if exists crm_leads_start_assignment on public.crm_leads;
create trigger crm_leads_start_assignment
  after insert on public.crm_leads for each row execute procedure public.start_lead_assignment();

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.crm_leads
  set assignment_status = 'accepted', assignment_deadline_at = null, stage = 'Em atendimento'
  where id = p_lead_id and owner_id = auth.uid() and assignment_status = 'pending';
  if not found then raise exception 'Este lead não está mais disponível para aceite.'; end if;
  update public.lead_assignment_attempts
  set accepted_at = now()
  where lead_id = p_lead_id and broker_id = auth.uid() and accepted_at is null and expired_at is null;
end;
$$;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

create or replace function public.process_expired_lead_assignments()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record; next_broker record; next_position integer; attempt_count integer;
begin
  for lead_row in
    select * from public.crm_leads
    where assignment_status = 'pending' and assignment_deadline_at <= now()
    for update skip locked
  loop
    update public.lead_assignment_attempts set expired_at = now()
    where lead_id = lead_row.id and accepted_at is null and expired_at is null;
    select count(*) into attempt_count from public.lead_assignment_attempts where lead_id = lead_row.id;
    perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_row.lead_type));
    select q.broker_id, p.full_name, p.email into next_broker
    from public.lead_distribution_queue q join public.profiles p on p.id = q.broker_id
    where q.lead_type = lead_row.lead_type and p.role = 'broker'
      and not exists (select 1 from public.lead_assignment_attempts a where a.lead_id = lead_row.id and a.broker_id = q.broker_id)
    order by q.position limit 1 for update of q skip locked;
    if next_broker.broker_id is null then
      update public.crm_leads set assignment_status = 'exhausted', assignment_deadline_at = null where id = lead_row.id;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      select id, 'lead_unanswered', 'Nenhum corretor assumiu o lead',
        lead_row.name || ' não foi atendido por nenhum corretor da fila.', '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name)
      from public.profiles where role = 'admin';
    else
      select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = lead_row.lead_type;
      update public.lead_distribution_queue set position = next_position, updated_at = now()
      where lead_type = lead_row.lead_type and broker_id = next_broker.broker_id;
      update public.crm_leads set owner_id = next_broker.broker_id, assignment_deadline_at = now() + interval '4 minutes', stage = 'Aguardando atendimento'
      where id = lead_row.id;
      insert into public.lead_assignment_attempts (lead_id, broker_id, attempt_number, deadline_at)
      values (lead_row.id, next_broker.broker_id, attempt_count + 1, now() + interval '4 minutes');
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (next_broker.broker_id, 'lead_assignment', 'Novo lead aguardando atendimento',
        'Você tem 4 minutos para iniciar o atendimento de ' || lead_row.name || '.', '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name));
    end if;
  end loop;
end;
$$;
