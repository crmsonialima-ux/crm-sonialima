-- Conta de validacao e trilha operacional imutavel do CRM.
--
-- Importante: `delivered_at` era preenchido pelo processador antigo mesmo quando
-- nao havia uma inscricao push elegivel. Por isso os registros anteriores sao
-- classificados como `processed_legacy`, e nao como entrega comprovada.

alter table public.profiles
  add column if not exists is_validator boolean not null default false;

-- O acesso informado pelo administrador permanece com todas as permissoes de
-- admin, mas e o unico inicialmente autorizado a abrir a area de validacao.
insert into public.profiles (id, full_name, email, role, is_validator)
select
  auth_user.id,
  coalesce(
    nullif(auth_user.raw_user_meta_data ->> 'full_name', ''),
    split_part(coalesce(auth_user.email, ''), '@', 1),
    'Validacao'
  ),
  coalesce(auth_user.email, 'crmsoniaallyson@gmail.com'),
  'admin'::public.crm_role,
  true
from auth.users as auth_user
where auth_user.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
   or lower(auth_user.email) = 'crmsoniaallyson@gmail.com'
on conflict (id) do update
set full_name = case
      when nullif(public.profiles.full_name, '') is null then excluded.full_name
      else public.profiles.full_name
    end,
    email = excluded.email,
    role = 'admin'::public.crm_role,
    is_validator = true,
    updated_at = now();

update public.profiles
set is_validator = false,
    updated_at = now()
where is_validator
  and id <> '37094db7-2457-48f2-8573-40c887e547e5'::uuid
  and lower(email) <> 'crmsoniaallyson@gmail.com';

create unique index if not exists profiles_single_validator_idx
  on public.profiles ((is_validator))
  where is_validator;

do $$
begin
  if not exists (
    select 1
    from public.profiles
    where id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
      and lower(email) = 'crmsoniaallyson@gmail.com'
      and role = 'admin'
      and is_validator
  ) then
    raise exception 'A conta crmsoniaallyson@gmail.com nao foi encontrada em auth.users.';
  end if;
end;
$$;

create or replace function public.is_validator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.role = 'admin'
      and profile.is_validator
  );
$$;

revoke all on function public.is_validator() from public, anon;
grant execute on function public.is_validator() to authenticated, service_role;

-- Impede que outro admin habilite a area exclusiva pelo cliente ou remova sem
-- querer a permissao da conta de validacao. Migrations e service_role continuam
-- autorizados a administrar a marcacao.
create or replace function public.protect_validator_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- auth.uid() permanece preenchido dentro de SECURITY DEFINER quando a
  -- chamada nasceu de uma sessao do CRM. Jobs/migrations do backend nao tem
  -- usuario final e podem administrar a marcacao.
  if auth.uid() is not null
     and (
       new.is_validator is distinct from old.is_validator
       or (
         old.is_validator
         and (
           new.role is distinct from old.role
           or lower(new.email) is distinct from lower(old.email)
         )
       )
     ) then
    raise exception 'A conta de validacao so pode ser alterada pelo backend seguro.';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_validator_profile() from public, anon, authenticated;

drop trigger if exists profiles_protect_validator on public.profiles;
create trigger profiles_protect_validator
before update of role, email, is_validator
on public.profiles
for each row execute function public.protect_validator_profile();

alter table public.crm_notification_outbox
  add column if not exists delivery_status text not null default 'queued',
  add column if not exists delivery_attempt_count integer not null default 0,
  add column if not exists last_delivery_attempt_at timestamptz,
  add column if not exists last_delivery_http_status integer,
  add column if not exists last_delivery_error text,
  add column if not exists delivery_updated_at timestamptz not null default now();

alter table public.crm_notification_outbox
  drop constraint if exists crm_notification_outbox_delivery_status_check;

alter table public.crm_notification_outbox
  add constraint crm_notification_outbox_delivery_status_check
  check (delivery_status in (
    'queued',
    'processing',
    'sent',
    'failed',
    'no_subscription',
    'invalid_subscription',
    'processed_legacy'
  ));

alter table public.crm_notification_outbox
  drop constraint if exists crm_notification_outbox_delivery_attempt_count_check;

alter table public.crm_notification_outbox
  add constraint crm_notification_outbox_delivery_attempt_count_check
  check (delivery_attempt_count >= 0);

update public.crm_notification_outbox
set delivery_status = case
      when delivered_at is not null then 'processed_legacy'
      else 'queued'
    end,
    delivery_updated_at = coalesce(delivered_at, created_at, now())
where delivery_status = 'queued'
   or delivery_status is null;

create index if not exists crm_notification_outbox_validator_timeline_idx
  on public.crm_notification_outbox (recipient_id, created_at desc);

create index if not exists crm_notification_outbox_delivery_status_idx
  on public.crm_notification_outbox (delivery_status, created_at)
  where delivery_status <> 'sent';

-- Eventos genericos por pessoa. Nao ha FK para notificacoes/perfis de proposito:
-- o historico continua existindo mesmo quando o registro operacional e apagado.
create table if not exists public.crm_audit_events (
  id bigint generated always as identity primary key,
  dedupe_key text unique,
  subject_user_id uuid,
  subject_name text,
  subject_email text,
  actor_user_id uuid,
  actor_email text,
  category text not null,
  event_type text not null,
  status text,
  entity_type text,
  entity_id uuid,
  notification_id uuid,
  happened_at timestamptz not null default now(),
  summary text not null default '',
  details jsonb not null default '{}'::jsonb,
  error_message text,
  created_at timestamptz not null default now()
);

create index if not exists crm_audit_events_subject_timeline_idx
  on public.crm_audit_events (subject_user_id, happened_at desc, id desc);

create index if not exists crm_audit_events_notification_idx
  on public.crm_audit_events (notification_id, happened_at, id)
  where notification_id is not null;

create index if not exists crm_audit_events_errors_idx
  on public.crm_audit_events (happened_at desc)
  where status = 'error' or error_message is not null;

alter table public.crm_audit_events enable row level security;
revoke all on public.crm_audit_events from public, anon, authenticated;
grant select on public.crm_audit_events to authenticated;

drop policy if exists "Only validators read the CRM audit trail" on public.crm_audit_events;
create policy "Only validators read the CRM audit trail"
  on public.crm_audit_events
  for select
  using (public.is_validator());

-- Uma linha para cada tentativa real de envio a uma inscricao push. O endpoint
-- e as chaves criptograficas nunca sao copiados para a auditoria.
create table if not exists public.crm_notification_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null,
  recipient_id uuid not null,
  subscription_id uuid,
  channel text not null default 'web_push',
  status text not null,
  attempted_at timestamptz not null default now(),
  completed_at timestamptz,
  http_status integer,
  error_code text,
  error_message text,
  details jsonb not null default '{}'::jsonb,
  constraint crm_notification_delivery_attempts_status_check
    check (status in (
      'processing',
      'sent',
      'failed',
      'no_subscription',
      'invalid_subscription',
      'skipped'
    ))
);

create index if not exists crm_notification_delivery_attempts_notification_idx
  on public.crm_notification_delivery_attempts (notification_id, attempted_at, id);

create index if not exists crm_notification_delivery_attempts_recipient_idx
  on public.crm_notification_delivery_attempts (recipient_id, attempted_at desc);

alter table public.crm_notification_delivery_attempts enable row level security;
revoke all on public.crm_notification_delivery_attempts from public, anon, authenticated;
grant select on public.crm_notification_delivery_attempts to authenticated;

drop policy if exists "Only validators read notification delivery attempts"
  on public.crm_notification_delivery_attempts;
create policy "Only validators read notification delivery attempts"
  on public.crm_notification_delivery_attempts
  for select
  using (public.is_validator());

-- O validator pode consultar o historico completo da outbox. Administradores
-- comuns continuam vendo apenas suas proprias notificacoes.
drop policy if exists "Validators read every notification history"
  on public.crm_notification_outbox;
create policy "Validators read every notification history"
  on public.crm_notification_outbox
  for select
  using (public.is_validator());

create or replace function public.append_crm_audit_event(
  p_subject_user_id uuid,
  p_actor_user_id uuid,
  p_category text,
  p_event_type text,
  p_status text,
  p_entity_type text,
  p_entity_id uuid,
  p_notification_id uuid,
  p_happened_at timestamptz,
  p_summary text,
  p_details jsonb,
  p_error_message text,
  p_dedupe_key text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id bigint;
  effective_actor uuid := coalesce(p_actor_user_id, auth.uid());
  subject_profile record;
  actor_profile record;
begin
  select full_name, email into subject_profile
  from public.profiles
  where id = p_subject_user_id;

  select email into actor_profile
  from public.profiles
  where id = effective_actor;

  insert into public.crm_audit_events (
    dedupe_key,
    subject_user_id,
    subject_name,
    subject_email,
    actor_user_id,
    actor_email,
    category,
    event_type,
    status,
    entity_type,
    entity_id,
    notification_id,
    happened_at,
    summary,
    details,
    error_message
  ) values (
    nullif(p_dedupe_key, ''),
    p_subject_user_id,
    subject_profile.full_name,
    subject_profile.email,
    effective_actor,
    actor_profile.email,
    left(coalesce(nullif(trim(p_category), ''), 'system'), 80),
    left(coalesce(nullif(trim(p_event_type), ''), 'unknown'), 120),
    left(nullif(trim(coalesce(p_status, '')), ''), 40),
    left(nullif(trim(coalesce(p_entity_type, '')), ''), 80),
    p_entity_id,
    p_notification_id,
    coalesce(p_happened_at, now()),
    left(coalesce(p_summary, ''), 1000),
    coalesce(p_details, '{}'::jsonb),
    left(nullif(coalesce(p_error_message, ''), ''), 4000)
  )
  on conflict (dedupe_key) do nothing
  returning id into event_id;

  return event_id;
end;
$$;

revoke all on function public.append_crm_audit_event(
  uuid,uuid,text,text,text,text,uuid,uuid,timestamptz,text,jsonb,text,text
) from public, anon, authenticated;

create or replace function public.normalize_crm_notification_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.delivered_at is null
     and new.delivered_at is not null
     and new.delivery_status = 'queued' then
    -- Compatibilidade com o processador atual. O significado exato so passa a
    -- ser conhecido quando ele usar record_notification_delivery_attempt().
    new.delivery_status := 'processed_legacy';
  end if;

  if new.delivery_status is distinct from old.delivery_status
     or new.delivery_attempt_count is distinct from old.delivery_attempt_count
     or new.last_delivery_attempt_at is distinct from old.last_delivery_attempt_at
     or new.last_delivery_error is distinct from old.last_delivery_error
     or new.delivered_at is distinct from old.delivered_at then
    new.delivery_updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.normalize_crm_notification_delivery()
  from public, anon, authenticated;

drop trigger if exists crm_notification_normalize_delivery
  on public.crm_notification_outbox;
create trigger crm_notification_normalize_delivery
before update on public.crm_notification_outbox
for each row execute function public.normalize_crm_notification_delivery();

create or replace function public.audit_crm_notification_outbox()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  snapshot jsonb;
begin
  if tg_op = 'DELETE' then
    snapshot := jsonb_build_object(
      'kind', old.kind,
      'title', old.title,
      'body', old.body,
      'url', old.url,
      'payload', old.payload,
      'deliveryStatus', old.delivery_status,
      'createdAt', old.created_at,
      'readAt', old.read_at,
      'dismissedAt', old.dismissed_at
    );
    perform public.append_crm_audit_event(
      old.recipient_id, auth.uid(), 'notification', 'notification_deleted',
      'deleted', 'notification', old.id, old.id, now(), old.title,
      snapshot, null, null
    );
    return old;
  end if;

  snapshot := jsonb_build_object(
    'kind', new.kind,
    'title', new.title,
    'body', new.body,
    'url', new.url,
    'payload', new.payload
  );

  if tg_op = 'INSERT' then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification', 'notification_queued',
      'queued', 'notification', new.id, new.id, new.created_at, new.title,
      snapshot, null, 'notification:' || new.id || ':queued'
    );
    return new;
  end if;

  if new.delivery_status is distinct from old.delivery_status then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification', 'delivery_status_changed',
      new.delivery_status, 'notification', new.id, new.id,
      coalesce(new.delivery_updated_at, now()), new.title,
      snapshot || jsonb_build_object(
        'previousStatus', old.delivery_status,
        'deliveryStatus', new.delivery_status,
        'attemptCount', new.delivery_attempt_count,
        'httpStatus', new.last_delivery_http_status
      ),
      new.last_delivery_error,
      null
    );
  end if;

  if old.delivered_at is null and new.delivered_at is not null then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification',
      case
        when new.delivery_status = 'sent' then 'push_accepted_by_provider'
        else 'legacy_delivery_processed'
      end,
      new.delivery_status, 'notification', new.id, new.id,
      new.delivered_at, new.title, snapshot, new.last_delivery_error,
      'notification:' || new.id || ':processed:' || extract(epoch from new.delivered_at)::text
    );
  end if;

  if old.read_at is null and new.read_at is not null then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification', 'inbox_read',
      'read', 'notification', new.id, new.id, new.read_at, new.title,
      snapshot, null,
      'notification:' || new.id || ':read:' || extract(epoch from new.read_at)::text
    );
  end if;

  if old.dismissed_at is null and new.dismissed_at is not null then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification', 'inbox_dismissed',
      'dismissed', 'notification', new.id, new.id, new.dismissed_at, new.title,
      snapshot, null,
      'notification:' || new.id || ':dismissed:' || extract(epoch from new.dismissed_at)::text
    );
  end if;

  if new.last_delivery_error is not null
     and new.last_delivery_error is distinct from old.last_delivery_error then
    perform public.append_crm_audit_event(
      new.recipient_id, auth.uid(), 'notification', 'notification_delivery_error',
      'error', 'notification', new.id, new.id,
      coalesce(new.last_delivery_attempt_at, now()), new.title,
      snapshot || jsonb_build_object('httpStatus', new.last_delivery_http_status),
      new.last_delivery_error, null
    );
  end if;

  return new;
end;
$$;

revoke all on function public.audit_crm_notification_outbox()
  from public, anon, authenticated;

drop trigger if exists crm_notification_outbox_audit
  on public.crm_notification_outbox;
create trigger crm_notification_outbox_audit
after insert or update or delete on public.crm_notification_outbox
for each row execute function public.audit_crm_notification_outbox();

-- Chamada pela Edge Function para registrar cada tentativa sem expor as
-- inscricoes push aos usuarios do navegador.
create or replace function public.record_notification_delivery_attempt(
  p_notification_id uuid,
  p_subscription_id uuid,
  p_status text,
  p_http_status integer default null,
  p_error_code text default null,
  p_error_message text default null,
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  notification_record public.crm_notification_outbox;
  attempt_id uuid;
  attempted_at timestamptz := now();
  mapped_status text;
begin
  if p_status is null or p_status not in (
    'processing', 'sent', 'failed', 'no_subscription',
    'invalid_subscription', 'skipped'
  ) then
    raise exception 'Status de entrega invalido.';
  end if;

  select * into notification_record
  from public.crm_notification_outbox
  where id = p_notification_id
  for update;
  if not found then raise exception 'Notificacao nao encontrada.'; end if;

  insert into public.crm_notification_delivery_attempts (
    notification_id,
    recipient_id,
    subscription_id,
    status,
    attempted_at,
    completed_at,
    http_status,
    error_code,
    error_message,
    details
  ) values (
    notification_record.id,
    notification_record.recipient_id,
    p_subscription_id,
    p_status,
    attempted_at,
    case when p_status = 'processing' then null else attempted_at end,
    p_http_status,
    left(nullif(coalesce(p_error_code, ''), ''), 120),
    left(nullif(coalesce(p_error_message, ''), ''), 4000),
    coalesce(p_details, '{}'::jsonb)
  ) returning id into attempt_id;

  mapped_status := case
    when p_status = 'skipped' then notification_record.delivery_status
    else p_status
  end;

  update public.crm_notification_outbox
  set delivery_status = mapped_status,
      delivery_attempt_count = delivery_attempt_count + 1,
      last_delivery_attempt_at = attempted_at,
      last_delivery_http_status = p_http_status,
      last_delivery_error = case
        when p_status in ('failed', 'invalid_subscription')
          then coalesce(nullif(p_error_message, ''), nullif(p_error_code, ''), 'Falha sem mensagem.')
        else null
      end,
      delivered_at = case
        when p_status = 'sent' then coalesce(delivered_at, attempted_at)
        else delivered_at
      end
  where id = notification_record.id;

  perform public.append_crm_audit_event(
    notification_record.recipient_id,
    null,
    'notification',
    'push_delivery_attempt',
    p_status,
    'notification',
    notification_record.id,
    notification_record.id,
    attempted_at,
    notification_record.title,
    jsonb_build_object(
      'attemptId', attempt_id,
      'subscriptionId', p_subscription_id,
      'httpStatus', p_http_status,
      'errorCode', p_error_code,
      'details', coalesce(p_details, '{}'::jsonb)
    ),
    p_error_message,
    null
  );

  return attempt_id;
end;
$$;

revoke all on function public.record_notification_delivery_attempt(
  uuid,uuid,text,integer,text,text,jsonb
) from public, anon, authenticated;
grant execute on function public.record_notification_delivery_attempt(
  uuid,uuid,text,integer,text,text,jsonb
) to service_role;

-- Eventos comprovaveis do cliente: apresentacao pelo browser, clique e
-- fechamento da notificacao do sistema operacional. "read" continua sendo o
-- clique/acao explicita na caixa de entrada, nao uma suposicao visual.
create or replace function public.record_notification_client_event(
  p_notification_id uuid,
  p_event_type text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  notification_record public.crm_notification_outbox;
  event_time timestamptz := now();
  reported_time timestamptz;
  client_event_id text;
  event_id bigint;
begin
  if p_event_type not in (
    'browser_presented', 'push_clicked', 'push_closed',
    'inbox_opened', 'notification_client_error'
  ) then
    raise exception 'Evento de notificacao invalido.';
  end if;

  select * into notification_record
  from public.crm_notification_outbox
  where id = p_notification_id
    and recipient_id = auth.uid();
  if not found then raise exception 'Notificacao nao encontrada para este usuario.'; end if;

  -- O service worker pode guardar o evento offline e sincroniza-lo quando o
  -- CRM abrir novamente. Aceitamos o horario informado somente dentro de uma
  -- janela plausivel, evitando datas arbitrarias no historico.
  begin
    reported_time := nullif(p_details ->> 'happenedAt', '')::timestamptz;
  exception when others then
    reported_time := null;
  end;
  if reported_time between now() - interval '30 days' and now() + interval '5 minutes' then
    event_time := reported_time;
  end if;

  if p_event_type in ('push_clicked', 'inbox_opened') then
    update public.crm_notification_outbox
    set read_at = coalesce(read_at, event_time)
    where id = notification_record.id;
  end if;

  client_event_id := nullif(coalesce(p_details ->> 'clientEventId', ''), '');
  event_id := public.append_crm_audit_event(
    notification_record.recipient_id,
    auth.uid(),
    'notification',
    p_event_type,
    case
      when p_event_type = 'notification_client_error' then 'error'
      else 'recorded'
    end,
    'notification',
    notification_record.id,
    notification_record.id,
    event_time,
    notification_record.title,
    coalesce(p_details, '{}'::jsonb),
    case
      when p_event_type = 'notification_client_error'
        then left(coalesce(p_details ->> 'message', 'Erro do cliente sem mensagem.'), 4000)
      else null
    end,
    case
      when client_event_id is null then null
      else 'notification:' || notification_record.id || ':client:' || client_event_id
    end
  );
  return event_id;
end;
$$;

revoke all on function public.record_notification_client_event(uuid,text,jsonb)
  from public, anon;
grant execute on function public.record_notification_client_event(uuid,text,jsonb)
  to authenticated;

create or replace function public.record_crm_client_error(
  p_area text,
  p_operation text,
  p_message text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  if nullif(trim(coalesce(p_message, '')), '') is null then
    raise exception 'Informe a mensagem do erro.';
  end if;

  return public.append_crm_audit_event(
    auth.uid(), auth.uid(), 'error', 'client_error', 'error',
    left(coalesce(nullif(trim(p_area), ''), 'client'), 80), null, null, now(),
    left(coalesce(nullif(trim(p_operation), ''), 'Operacao no CRM'), 1000),
    coalesce(p_details, '{}'::jsonb), p_message, null
  );
end;
$$;

revoke all on function public.record_crm_client_error(text,text,text,jsonb)
  from public, anon;
grant execute on function public.record_crm_client_error(text,text,text,jsonb)
  to authenticated;

create or replace function public.record_crm_system_error(
  p_subject_user_id uuid,
  p_area text,
  p_operation text,
  p_message text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
begin
  if nullif(trim(coalesce(p_message, '')), '') is null then
    raise exception 'Informe a mensagem do erro.';
  end if;
  return public.append_crm_audit_event(
    p_subject_user_id, null, 'error', 'system_error', 'error',
    left(coalesce(nullif(trim(p_area), ''), 'backend'), 80), null, null, now(),
    left(coalesce(nullif(trim(p_operation), ''), 'Operacao do backend'), 1000),
    coalesce(p_details, '{}'::jsonb), p_message, null
  );
end;
$$;

revoke all on function public.record_crm_system_error(uuid,text,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.record_crm_system_error(uuid,text,text,text,jsonb)
  to service_role;

-- Passos de leads, agenda e inscricao push entram na mesma linha do tempo por
-- usuario. Os triggers guardam somente metadados necessarios para validacao.
create or replace function public.audit_lead_assignment_attempt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- Uma notificacao que ficou sem dispositivo volta para a fila assim que o
    -- usuario habilita um novo aparelho. O processador ainda aplicara o limite
    -- de tentativas e a janela de expediente antes do envio.
    update public.crm_notification_outbox
    set delivery_status = 'queued',
        last_delivery_error = null,
        last_delivery_http_status = null
    where recipient_id = new.user_id
      and delivered_at is null
      and delivery_status in ('no_subscription', 'invalid_subscription');

    perform public.append_crm_audit_event(
      new.broker_id, auth.uid(), 'lead', 'lead_assignment_attempt_created',
      'pending', 'lead', new.lead_id, null, new.notified_at,
      'Lead encaminhado ao corretor',
      jsonb_build_object(
        'attemptId', new.id,
        'attemptNumber', new.attempt_number,
        'deadlineAt', new.deadline_at
      ), null, 'assignment-attempt:' || new.id || ':created'
    );
  elsif tg_op = 'UPDATE' then
    if old.accepted_at is null and new.accepted_at is not null then
      perform public.append_crm_audit_event(
        new.broker_id, auth.uid(), 'lead', 'lead_assignment_accepted',
        'completed', 'lead', new.lead_id, null, new.accepted_at,
        'Corretor assumiu o lead',
        jsonb_build_object('attemptId', new.id, 'attemptNumber', new.attempt_number),
        null, 'assignment-attempt:' || new.id || ':accepted'
      );
    end if;
    if old.expired_at is null and new.expired_at is not null then
      perform public.append_crm_audit_event(
        new.broker_id, auth.uid(), 'lead', 'lead_assignment_expired',
        'expired', 'lead', new.lead_id, null, new.expired_at,
        'Prazo do corretor expirou',
        jsonb_build_object('attemptId', new.id, 'attemptNumber', new.attempt_number),
        null, 'assignment-attempt:' || new.id || ':expired'
      );
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.audit_lead_assignment_attempt()
  from public, anon, authenticated;
drop trigger if exists lead_assignment_attempt_audit
  on public.lead_assignment_attempts;
create trigger lead_assignment_attempt_audit
after insert or update on public.lead_assignment_attempts
for each row execute function public.audit_lead_assignment_attempt();

create or replace function public.audit_lead_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  lead_owner uuid;
begin
  select owner_id into lead_owner
  from public.crm_leads
  where id = new.lead_id;

  perform public.append_crm_audit_event(
    lead_owner, new.author_id, 'lead', 'lead_activity_created',
    'recorded', 'lead', new.lead_id, null, new.created_at,
    coalesce(nullif(new.stage, ''), 'Atividade do lead'),
    jsonb_build_object(
      'activityId', new.id,
      'stage', new.stage,
      'note', new.note,
      'authorName', new.author_name
    ), null, 'lead-activity:' || new.id || ':created'
  );
  return new;
end;
$$;

revoke all on function public.audit_lead_activity()
  from public, anon, authenticated;
drop trigger if exists crm_lead_activity_audit on public.crm_lead_activities;
create trigger crm_lead_activity_audit
after insert on public.crm_lead_activities
for each row execute function public.audit_lead_activity();

create or replace function public.audit_crm_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.append_crm_audit_event(
      new.owner_id, new.created_by, 'lead', 'lead_created', 'created',
      'lead', new.id, null, new.created_at, new.name,
      jsonb_build_object(
        'stage', new.stage,
        'channel', new.channel,
        'propertyInterest', new.property_interest,
        'assignmentStatus', new.assignment_status
      ), null, 'lead:' || new.id || ':created'
    );
  elsif tg_op = 'UPDATE' then
    if new.owner_id is distinct from old.owner_id then
      perform public.append_crm_audit_event(
        new.owner_id, auth.uid(), 'lead', 'lead_owner_changed', 'recorded',
        'lead', new.id, null, now(), new.name,
        jsonb_build_object('previousOwnerId', old.owner_id, 'ownerId', new.owner_id),
        null, null
      );
    end if;
    if new.stage is distinct from old.stage then
      perform public.append_crm_audit_event(
        new.owner_id, auth.uid(), 'lead', 'lead_stage_changed', 'recorded',
        'lead', new.id, null, now(), new.name,
        jsonb_build_object('previousStage', old.stage, 'stage', new.stage),
        null, null
      );
    end if;
    if new.assignment_status is distinct from old.assignment_status then
      perform public.append_crm_audit_event(
        new.owner_id, auth.uid(), 'lead', 'lead_assignment_status_changed',
        new.assignment_status, 'lead', new.id, null, now(), new.name,
        jsonb_build_object(
          'previousStatus', old.assignment_status,
          'assignmentStatus', new.assignment_status,
          'deadlineAt', new.assignment_deadline_at
        ), null, null
      );
    end if;
  elsif tg_op = 'DELETE' then
    perform public.append_crm_audit_event(
      old.owner_id, auth.uid(), 'lead', 'lead_deleted', 'deleted',
      'lead', old.id, null, now(), old.name,
      jsonb_build_object('stage', old.stage, 'channel', old.channel), null, null
    );
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.audit_crm_lead()
  from public, anon, authenticated;
drop trigger if exists crm_lead_audit on public.crm_leads;
create trigger crm_lead_audit
after insert or update or delete on public.crm_leads
for each row execute function public.audit_crm_lead();

create or replace function public.audit_crm_agenda_entry()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_row jsonb;
  new_row jsonb;
  actor_id uuid;
begin
  if tg_op = 'DELETE' then
    perform public.append_crm_audit_event(
      old.target_user_id, auth.uid(), 'agenda', 'agenda_entry_deleted', 'deleted',
      'agenda', old.id, null, now(), old.observation,
      jsonb_build_object('category', old.category, 'scheduledAt', old.scheduled_at),
      null, null
    );
    return old;
  end if;

  new_row := to_jsonb(new);
  if tg_op = 'INSERT' then
    perform public.append_crm_audit_event(
      new.target_user_id, new.created_by, 'agenda', 'agenda_entry_created',
      'created', 'agenda', new.id, null, new.created_at, new.observation,
      jsonb_build_object(
        'category', new.category,
        'scheduledAt', new.scheduled_at,
        'createdByEmail', new_row ->> 'created_by_email',
        'sourceKind', new_row ->> 'source_kind'
      ), null, 'agenda:' || new.id || ':created'
    );
    return new;
  end if;

  old_row := to_jsonb(old);
  actor_id := auth.uid();

  if old.feedback_at is null and new.feedback_at is not null then
    perform public.append_crm_audit_event(
      new.target_user_id, new.feedback_by, 'agenda', 'agenda_feedback_recorded',
      'completed', 'agenda', new.id, null, new.feedback_at, new.observation,
      jsonb_build_object('note', new.feedback_note), null, null
    );
  end if;

  if coalesce((new_row ->> 'cartorio_protocol_revision_count')::integer, 0)
     > coalesce((old_row ->> 'cartorio_protocol_revision_count')::integer, 0) then
    perform public.append_crm_audit_event(
      new.target_user_id, actor_id, 'agenda', 'cartorio_protocol_saved',
      'completed', 'agenda', new.id, null, now(), new.observation,
      jsonb_build_object(
        'revision', new_row ->> 'cartorio_protocol_revision_count',
        'entryDate', new_row ->> 'protocol_entry_date',
        'expectedDate', new_row ->> 'protocol_expected_date',
        'attachmentCount', case
          when jsonb_typeof(new_row -> 'protocol_paths') = 'array'
            then jsonb_array_length(new_row -> 'protocol_paths')
          else 0
        end
      ), null, null
    );
  end if;

  if nullif(old_row ->> 'cartorio_received_at', '') is null
     and nullif(new_row ->> 'cartorio_received_at', '') is not null then
    perform public.append_crm_audit_event(
      new.target_user_id, actor_id, 'agenda', 'cartorio_received',
      'completed', 'agenda', new.id, null,
      (new_row ->> 'cartorio_received_at')::timestamptz,
      new.observation, '{}'::jsonb, null, null
    );
  end if;

  if nullif(old_row ->> 'cartorio_delivered_to_vitor_at', '') is null
     and nullif(new_row ->> 'cartorio_delivered_to_vitor_at', '') is not null then
    perform public.append_crm_audit_event(
      new.target_user_id, actor_id, 'agenda', 'cartorio_delivered_to_vitor',
      'completed', 'agenda', new.id, null,
      (new_row ->> 'cartorio_delivered_to_vitor_at')::timestamptz,
      new.observation, '{}'::jsonb, null, null
    );
  end if;

  if nullif(old_row ->> 'cartorio_vitor_document_uploaded_at', '') is null
     and nullif(new_row ->> 'cartorio_vitor_document_uploaded_at', '') is not null then
    perform public.append_crm_audit_event(
      new.target_user_id,
      nullif(new_row ->> 'cartorio_vitor_document_uploaded_by', '')::uuid,
      'agenda', 'cartorio_vitor_document_uploaded', 'completed',
      'agenda', new.id, null,
      (new_row ->> 'cartorio_vitor_document_uploaded_at')::timestamptz,
      new.observation,
      jsonb_build_object(
        'attachmentCount', case
          when jsonb_typeof(new_row -> 'cartorio_vitor_document_paths') = 'array'
            then jsonb_array_length(new_row -> 'cartorio_vitor_document_paths')
          else 0
        end
      ), null, null
    );
  end if;

  return new;
end;
$$;

revoke all on function public.audit_crm_agenda_entry()
  from public, anon, authenticated;
drop trigger if exists crm_agenda_entry_audit on public.crm_agenda_entries;
create trigger crm_agenda_entry_audit
after insert or update or delete on public.crm_agenda_entries
for each row execute function public.audit_crm_agenda_entry();

create or replace function public.audit_push_subscription()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.append_crm_audit_event(
      new.user_id, auth.uid(), 'notification', 'push_subscription_created',
      'active', 'push_subscription', new.id, null, new.created_at,
      'Dispositivo habilitado para notificacoes', '{}'::jsonb, null,
      'push-subscription:' || new.id || ':created'
    );
    return new;
  elsif tg_op = 'DELETE' then
    perform public.append_crm_audit_event(
      old.user_id, auth.uid(), 'notification', 'push_subscription_removed',
      'removed', 'push_subscription', old.id, null, now(),
      'Dispositivo removido das notificacoes', '{}'::jsonb, null, null
    );
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.audit_push_subscription()
  from public, anon, authenticated;
drop trigger if exists push_subscription_audit on public.push_subscriptions;
create trigger push_subscription_audit
after insert or delete on public.push_subscriptions
for each row execute function public.audit_push_subscription();

-- Reconstrucao honesta do historico que o banco ja consegue provar.
insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id, notification_id,
  happened_at, summary, details
)
select
  'notification:' || notification.id || ':queued',
  notification.recipient_id,
  profile.full_name,
  profile.email,
  'notification',
  'notification_queued',
  'queued',
  'notification',
  notification.id,
  notification.id,
  notification.created_at,
  notification.title,
  jsonb_build_object(
    'kind', notification.kind,
    'title', notification.title,
    'body', notification.body,
    'url', notification.url,
    'payload', notification.payload,
    'historicalBackfill', true
  )
from public.crm_notification_outbox as notification
left join public.profiles as profile on profile.id = notification.recipient_id
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id, notification_id,
  happened_at, summary, details
)
select
  'notification:' || notification.id || ':processed:' || extract(epoch from notification.delivered_at)::text,
  notification.recipient_id,
  profile.full_name,
  profile.email,
  'notification',
  'legacy_delivery_processed',
  'processed_legacy',
  'notification',
  notification.id,
  notification.id,
  notification.delivered_at,
  notification.title,
  jsonb_build_object(
    'kind', notification.kind,
    'historicalBackfill', true,
    'warning', 'O processador antigo nao diferenciava envio real de ausencia de inscricao push.'
  )
from public.crm_notification_outbox as notification
left join public.profiles as profile on profile.id = notification.recipient_id
where notification.delivered_at is not null
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id, notification_id,
  happened_at, summary, details
)
select
  'notification:' || notification.id || ':read:' || extract(epoch from notification.read_at)::text,
  notification.recipient_id,
  profile.full_name,
  profile.email,
  'notification', 'inbox_read', 'read', 'notification',
  notification.id, notification.id, notification.read_at, notification.title,
  jsonb_build_object('historicalBackfill', true)
from public.crm_notification_outbox as notification
left join public.profiles as profile on profile.id = notification.recipient_id
where notification.read_at is not null
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id, notification_id,
  happened_at, summary, details
)
select
  'notification:' || notification.id || ':dismissed:' || extract(epoch from notification.dismissed_at)::text,
  notification.recipient_id,
  profile.full_name,
  profile.email,
  'notification', 'inbox_dismissed', 'dismissed', 'notification',
  notification.id, notification.id, notification.dismissed_at, notification.title,
  jsonb_build_object('historicalBackfill', true)
from public.crm_notification_outbox as notification
left join public.profiles as profile on profile.id = notification.recipient_id
where notification.dismissed_at is not null
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  actor_user_id, actor_email, category, event_type, status,
  entity_type, entity_id, happened_at, summary, details
)
select
  'lead-activity:' || activity.id || ':created',
  lead.owner_id,
  owner_profile.full_name,
  owner_profile.email,
  activity.author_id,
  author_profile.email,
  'lead', 'lead_activity_created', 'recorded', 'lead', activity.lead_id,
  activity.created_at,
  coalesce(nullif(activity.stage, ''), 'Atividade do lead'),
  jsonb_build_object(
    'activityId', activity.id,
    'stage', activity.stage,
    'note', activity.note,
    'authorName', activity.author_name,
    'historicalBackfill', true
  )
from public.crm_lead_activities as activity
join public.crm_leads as lead on lead.id = activity.lead_id
left join public.profiles as owner_profile on owner_profile.id = lead.owner_id
left join public.profiles as author_profile on author_profile.id = activity.author_id
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id,
  happened_at, summary, details
)
select
  'assignment-attempt:' || attempt.id || ':created',
  attempt.broker_id,
  profile.full_name,
  profile.email,
  'lead', 'lead_assignment_attempt_created', 'pending', 'lead', attempt.lead_id,
  attempt.notified_at,
  'Lead encaminhado ao corretor',
  jsonb_build_object(
    'attemptId', attempt.id,
    'attemptNumber', attempt.attempt_number,
    'deadlineAt', attempt.deadline_at,
    'historicalBackfill', true
  )
from public.lead_assignment_attempts as attempt
left join public.profiles as profile on profile.id = attempt.broker_id
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id,
  happened_at, summary, details
)
select
  'assignment-attempt:' || attempt.id || ':accepted',
  attempt.broker_id,
  profile.full_name,
  profile.email,
  'lead', 'lead_assignment_accepted', 'completed', 'lead', attempt.lead_id,
  attempt.accepted_at,
  'Corretor assumiu o lead',
  jsonb_build_object('attemptId', attempt.id, 'historicalBackfill', true)
from public.lead_assignment_attempts as attempt
left join public.profiles as profile on profile.id = attempt.broker_id
where attempt.accepted_at is not null
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  category, event_type, status, entity_type, entity_id,
  happened_at, summary, details
)
select
  'assignment-attempt:' || attempt.id || ':expired',
  attempt.broker_id,
  profile.full_name,
  profile.email,
  'lead', 'lead_assignment_expired', 'expired', 'lead', attempt.lead_id,
  attempt.expired_at,
  'Prazo do corretor expirou',
  jsonb_build_object('attemptId', attempt.id, 'historicalBackfill', true)
from public.lead_assignment_attempts as attempt
left join public.profiles as profile on profile.id = attempt.broker_id
where attempt.expired_at is not null
on conflict (dedupe_key) do nothing;

insert into public.crm_audit_events (
  dedupe_key, subject_user_id, subject_name, subject_email,
  actor_user_id, actor_email, category, event_type, status,
  entity_type, entity_id, happened_at, summary, details
)
select
  'agenda:' || agenda.id || ':created',
  agenda.target_user_id,
  target_profile.full_name,
  target_profile.email,
  agenda.created_by,
  creator_profile.email,
  'agenda', 'agenda_entry_created', 'created', 'agenda', agenda.id,
  agenda.created_at,
  agenda.observation,
  jsonb_build_object(
    'category', agenda.category,
    'scheduledAt', agenda.scheduled_at,
    'createdByEmail', to_jsonb(agenda) ->> 'created_by_email',
    'sourceKind', to_jsonb(agenda) ->> 'source_kind',
    'historicalBackfill', true
  )
from public.crm_agenda_entries as agenda
left join public.profiles as target_profile on target_profile.id = agenda.target_user_id
left join public.profiles as creator_profile on creator_profile.id = agenda.created_by
on conflict (dedupe_key) do nothing;

-- Registro explicito da promocao da conta de validacao.
select public.append_crm_audit_event(
  profile.id,
  null,
  'access',
  'validator_access_enabled',
  'active',
  'profile',
  profile.id,
  null,
  now(),
  'Acesso de validacao habilitado',
  jsonb_build_object('role', profile.role, 'email', profile.email),
  null,
  'validator:' || profile.id || ':enabled'
)
from public.profiles as profile
where profile.is_validator;

-- Snapshot unico usado pelo painel de validacao. A checagem ocorre dentro da
-- funcao SECURITY DEFINER; conhecer a URL/RPC nao concede acesso a outro admin.
create or replace function public.get_validation_audit(
  p_profile_id uuid default null,
  p_limit integer default 500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  row_limit integer := least(greatest(coalesce(p_limit, 500), 1), 1000);
  profiles_json jsonb;
  notifications_json jsonb;
  attempts_json jsonb;
  assignments_json jsonb;
  activities_json jsonb;
  agenda_json jsonb;
  events_json jsonb;
  errors_json jsonb;
begin
  if not public.is_validator() then
    raise exception 'Acesso exclusivo da conta de validacao.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(profile_row) order by profile_row.full_name), '[]'::jsonb)
  into profiles_json
  from (
    select
      profile.id,
      profile.full_name,
      profile.email,
      profile.role::text as role,
      profile.is_validator,
      count(notification.id)::integer as notification_count,
      count(notification.id) filter (where notification.read_at is null)::integer as unread_count,
      max(notification.created_at) as last_notification_at
    from public.profiles as profile
    left join public.crm_notification_outbox as notification
      on notification.recipient_id = profile.id
    where p_profile_id is null or profile.id = p_profile_id
    group by profile.id, profile.full_name, profile.email, profile.role, profile.is_validator
    order by profile.full_name, profile.email
  ) as profile_row;

  select coalesce(jsonb_agg(to_jsonb(notification_row) order by notification_row.created_at desc), '[]'::jsonb)
  into notifications_json
  from (
    select
      notification.id,
      notification.recipient_id,
      profile.full_name as recipient_name,
      profile.email as recipient_email,
      notification.kind,
      notification.title,
      notification.body,
      notification.url,
      notification.payload,
      notification.created_at,
      to_jsonb(notification) ->> 'available_at' as available_at,
      notification.delivery_status,
      notification.delivery_attempt_count,
      notification.last_delivery_attempt_at,
      notification.last_delivery_http_status,
      notification.last_delivery_error,
      notification.delivered_at as legacy_processed_or_sent_at,
      notification.read_at,
      notification.dismissed_at
    from public.crm_notification_outbox as notification
    left join public.profiles as profile on profile.id = notification.recipient_id
    where p_profile_id is null or notification.recipient_id = p_profile_id
    order by notification.created_at desc
    limit row_limit
  ) as notification_row;

  select coalesce(jsonb_agg(to_jsonb(attempt_row) order by attempt_row.attempted_at desc), '[]'::jsonb)
  into attempts_json
  from (
    select
      attempt.id,
      attempt.notification_id,
      attempt.recipient_id,
      profile.full_name as recipient_name,
      profile.email as recipient_email,
      attempt.subscription_id,
      attempt.channel,
      attempt.status,
      attempt.attempted_at,
      attempt.completed_at,
      attempt.http_status,
      attempt.error_code,
      attempt.error_message,
      attempt.details
    from public.crm_notification_delivery_attempts as attempt
    left join public.profiles as profile on profile.id = attempt.recipient_id
    where p_profile_id is null or attempt.recipient_id = p_profile_id
    order by attempt.attempted_at desc
    limit row_limit
  ) as attempt_row;

  select coalesce(jsonb_agg(to_jsonb(assignment_row) order by assignment_row.notified_at desc), '[]'::jsonb)
  into assignments_json
  from (
    select
      attempt.id,
      attempt.lead_id,
      lead.name as lead_name,
      attempt.broker_id,
      profile.full_name as broker_name,
      profile.email as broker_email,
      attempt.attempt_number,
      attempt.notified_at,
      attempt.deadline_at,
      attempt.accepted_at,
      attempt.expired_at
    from public.lead_assignment_attempts as attempt
    left join public.crm_leads as lead on lead.id = attempt.lead_id
    left join public.profiles as profile on profile.id = attempt.broker_id
    where p_profile_id is null or attempt.broker_id = p_profile_id
    order by attempt.notified_at desc
    limit row_limit
  ) as assignment_row;

  select coalesce(jsonb_agg(to_jsonb(activity_row) order by activity_row.created_at desc), '[]'::jsonb)
  into activities_json
  from (
    select
      activity.id,
      activity.lead_id,
      lead.name as lead_name,
      lead.owner_id,
      owner_profile.full_name as owner_name,
      owner_profile.email as owner_email,
      activity.stage,
      activity.note,
      activity.author_id,
      activity.author_name,
      author_profile.email as author_email,
      activity.created_at
    from public.crm_lead_activities as activity
    join public.crm_leads as lead on lead.id = activity.lead_id
    left join public.profiles as owner_profile on owner_profile.id = lead.owner_id
    left join public.profiles as author_profile on author_profile.id = activity.author_id
    where p_profile_id is null or lead.owner_id = p_profile_id or activity.author_id = p_profile_id
    order by activity.created_at desc
    limit row_limit
  ) as activity_row;

  select coalesce(jsonb_agg(to_jsonb(agenda_row) order by agenda_row.scheduled_at desc), '[]'::jsonb)
  into agenda_json
  from (
    select
      agenda.id,
      agenda.target_user_id,
      target_profile.full_name as target_name,
      target_profile.email as target_email,
      agenda.created_by,
      creator_profile.full_name as creator_name,
      creator_profile.email as creator_email,
      agenda.category::text as category,
      agenda.scheduled_at,
      agenda.observation,
      agenda.feedback_at,
      agenda.feedback_note,
      agenda.feedback_by,
      agenda.feedback_history,
      to_jsonb(agenda) -> 'cartorio_protocol_versions' as cartorio_protocol_versions,
      to_jsonb(agenda) ->> 'cartorio_received_at' as cartorio_received_at,
      to_jsonb(agenda) ->> 'cartorio_delivered_to_vitor_at' as cartorio_delivered_to_vitor_at,
      to_jsonb(agenda) ->> 'cartorio_vitor_document_uploaded_at' as cartorio_vitor_document_uploaded_at,
      agenda.created_at,
      agenda.updated_at
    from public.crm_agenda_entries as agenda
    left join public.profiles as target_profile on target_profile.id = agenda.target_user_id
    left join public.profiles as creator_profile on creator_profile.id = agenda.created_by
    where p_profile_id is null
       or agenda.target_user_id = p_profile_id
       or agenda.created_by = p_profile_id
       or agenda.feedback_by = p_profile_id
    order by agenda.scheduled_at desc
    limit row_limit
  ) as agenda_row;

  select coalesce(jsonb_agg(to_jsonb(event_row) order by event_row.happened_at desc, event_row.id desc), '[]'::jsonb)
  into events_json
  from (
    select
      event.id,
      event.subject_user_id,
      event.subject_name,
      event.subject_email,
      event.actor_user_id,
      event.actor_email,
      event.category,
      event.event_type,
      event.status,
      event.entity_type,
      event.entity_id,
      event.notification_id,
      event.happened_at,
      event.summary,
      event.details,
      event.error_message
    from public.crm_audit_events as event
    where p_profile_id is null
       or event.subject_user_id = p_profile_id
       or event.actor_user_id = p_profile_id
    order by event.happened_at desc, event.id desc
    limit row_limit
  ) as event_row;

  select coalesce(jsonb_agg(to_jsonb(error_row) order by error_row.happened_at desc, error_row.id desc), '[]'::jsonb)
  into errors_json
  from (
    select
      event.id,
      event.subject_user_id,
      event.subject_name,
      event.subject_email,
      event.actor_user_id,
      event.actor_email,
      event.category,
      event.event_type,
      event.entity_type,
      event.happened_at,
      event.summary,
      event.details,
      event.error_message
    from public.crm_audit_events as event
    where (event.status = 'error' or event.error_message is not null)
      and (
        p_profile_id is null
        or event.subject_user_id = p_profile_id
        or event.actor_user_id = p_profile_id
      )
    order by event.happened_at desc, event.id desc
    limit row_limit
  ) as error_row;

  return jsonb_build_object(
    'generatedAt', now(),
    'profileId', p_profile_id,
    'profiles', profiles_json,
    'notifications', notifications_json,
    'deliveryAttempts', attempts_json,
    'leadAssignments', assignments_json,
    'leadActivities', activities_json,
    'agendaEntries', agenda_json,
    'auditEvents', events_json,
    'systemErrors', errors_json,
    'legacyDeliveryWarning',
      'delivered_at anterior a esta auditoria significa processado, nao entrega comprovada no aparelho.'
  );
end;
$$;

revoke all on function public.get_validation_audit(uuid,integer)
  from public, anon;
grant execute on function public.get_validation_audit(uuid,integer)
  to authenticated;
