-- Modulo de financiamento: dados isolados, fluxo progressivo, auditoria e RLS.
-- Nenhuma linha existente de leads e alterada por esta migration.

alter table public.profiles
  add column if not exists is_financing_operator boolean not null default false;

update public.profiles
set is_financing_operator = true,
    updated_at = now()
where lower(email) = 'unassigned-operator@example.invalid';

create index if not exists profiles_financing_operator_idx
  on public.profiles (is_financing_operator)
  where is_financing_operator;

create or replace function public.is_financing_operator()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles profile
    where profile.id = auth.uid()
      and (profile.role = 'admin' or profile.is_financing_operator)
  );
$$;

revoke all on function public.is_financing_operator() from public, anon;
grant execute on function public.is_financing_operator() to authenticated, service_role;

create table if not exists public.crm_financing_processes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null unique references public.crm_leads(id) on delete cascade,
  broker_id uuid not null references public.profiles(id),
  operator_id uuid not null references public.profiles(id),
  activated_by uuid not null references public.profiles(id),
  activated_at timestamptz not null default now(),
  current_stage text not null default 'checklist'
    check (current_stage in (
      'checklist','documentation','credit','inspection','report','conformity','committee',
      'minutes','notary','registry_details','registry_phase','release_conformity','completed'
    )),
  status text not null default 'pending'
    check (status in (
      'pending','in_progress','awaiting_documents','awaiting_conformity','awaiting_registry',
      'inspection_not_requested','release_nonconform','credit_denied','report_denied','completed'
    )),
  checklist_sent boolean not null default false,
  checklist_sent_at timestamptz,
  checklist_sent_by uuid references public.profiles(id),
  documentation_complete boolean not null default false,
  documentation_completed_at timestamptz,
  documentation_completed_by uuid references public.profiles(id),
  credit_approved boolean,
  credit_approved_value numeric(14,2),
  credit_denial_reason text,
  credit_decided_at timestamptz,
  credit_decided_by uuid references public.profiles(id),
  inspection_requested boolean,
  inspection_requested_at timestamptz,
  inspection_requested_by uuid references public.profiles(id),
  report_result text check (report_result in ('approved','denied')),
  report_property_value numeric(14,2),
  report_denial_reason text,
  report_received_at timestamptz,
  report_received_by uuid references public.profiles(id),
  committee_sent_date date,
  committee_recorded_at timestamptz,
  committee_recorded_by uuid references public.profiles(id),
  minutes_issued boolean not null default false,
  minutes_issued_at timestamptz,
  minutes_issued_by uuid references public.profiles(id),
  notary_name text,
  deed_date date,
  deed_signing_date date,
  notary_completed_at timestamptz,
  notary_completed_by uuid references public.profiles(id),
  registry_opened_at timestamptz,
  registry_protocol text,
  registry_expected_delivery date,
  registry_details_completed_at timestamptz,
  registry_details_completed_by uuid references public.profiles(id),
  registry_phase text check (registry_phase in ('examination','registering','ready')),
  registry_phase_updated_at timestamptz,
  registry_phase_updated_by uuid references public.profiles(id),
  release_conformity_entry_date date,
  release_conform boolean,
  release_denial_reason text,
  credit_release_date date,
  release_decided_at timestamptz,
  release_decided_by uuid references public.profiles(id),
  completed_at timestamptz,
  completed_by uuid references public.profiles(id),
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (credit_approved is distinct from true or credit_approved_value > 0),
  check (credit_approved is distinct from false or nullif(btrim(credit_denial_reason), '') is not null),
  check (report_result is distinct from 'approved' or report_property_value > 0),
  check (report_result is distinct from 'denied' or nullif(btrim(report_denial_reason), '') is not null),
  check (release_conform is distinct from true or credit_release_date is not null),
  check (release_conform is distinct from false or nullif(btrim(release_denial_reason), '') is not null)
);

create table if not exists public.crm_financing_documents (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.crm_financing_processes(id) on delete cascade,
  document_key text not null,
  label text not null,
  position integer not null check (position > 0),
  status text not null default 'pending' check (status in ('pending','received')),
  received_at timestamptz,
  received_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (process_id, document_key),
  unique (process_id, position)
);

create table if not exists public.crm_financing_conformity_attempts (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.crm_financing_processes(id) on delete cascade,
  attempt_number integer not null check (attempt_number > 0),
  entry_date date,
  result text check (result in ('conform','nonconform')),
  return_date date,
  nonconformity_reason text,
  active boolean not null default true,
  started_at timestamptz not null default now(),
  started_by uuid not null references public.profiles(id),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id),
  restarted_at timestamptz,
  restarted_by uuid references public.profiles(id),
  unique (process_id, attempt_number),
  check (result is distinct from 'conform' or return_date is not null),
  check (result is distinct from 'nonconform' or nullif(btrim(nonconformity_reason), '') is not null)
);

create unique index if not exists crm_financing_one_active_conformity_idx
  on public.crm_financing_conformity_attempts(process_id)
  where active;

create table if not exists public.crm_financing_history (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.crm_financing_processes(id) on delete cascade,
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  stage text not null,
  action text not null,
  field_name text,
  old_value jsonb,
  new_value jsonb,
  actor_id uuid not null references public.profiles(id),
  actor_name text not null,
  note text,
  attempt_number integer,
  created_at timestamptz not null default now()
);

create index if not exists crm_financing_process_broker_idx
  on public.crm_financing_processes(broker_id, updated_at desc);
create index if not exists crm_financing_process_status_idx
  on public.crm_financing_processes(status, current_stage, updated_at desc);
create index if not exists crm_financing_documents_process_idx
  on public.crm_financing_documents(process_id, position);
create index if not exists crm_financing_conformity_process_idx
  on public.crm_financing_conformity_attempts(process_id, attempt_number desc);
create index if not exists crm_financing_history_process_idx
  on public.crm_financing_history(process_id, created_at desc, id desc);

create trigger crm_financing_processes_updated_at
  before update on public.crm_financing_processes
  for each row execute function public.set_updated_at();
create trigger crm_financing_documents_updated_at
  before update on public.crm_financing_documents
  for each row execute function public.set_updated_at();

create or replace function public.can_view_financing(p_process_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.crm_financing_processes process
    join public.profiles viewer on viewer.id = auth.uid()
    where process.id = p_process_id
      and (
        viewer.role = 'admin'
        or viewer.is_financing_operator
        or process.broker_id = viewer.id
      )
  );
$$;

revoke all on function public.can_view_financing(uuid) from public, anon;
grant execute on function public.can_view_financing(uuid) to authenticated, service_role;

alter table public.crm_financing_processes enable row level security;
alter table public.crm_financing_documents enable row level security;
alter table public.crm_financing_conformity_attempts enable row level security;
alter table public.crm_financing_history enable row level security;

revoke all on public.crm_financing_processes from public, anon, authenticated;
revoke all on public.crm_financing_documents from public, anon, authenticated;
revoke all on public.crm_financing_conformity_attempts from public, anon, authenticated;
revoke all on public.crm_financing_history from public, anon, authenticated;
grant select on public.crm_financing_processes to authenticated;
grant select on public.crm_financing_documents to authenticated;
grant select on public.crm_financing_conformity_attempts to authenticated;
grant select on public.crm_financing_history to authenticated;

create policy "Financing processes are visible to operator admin or owner"
  on public.crm_financing_processes for select
  using (
    broker_id=auth.uid()
    or exists (
      select 1 from public.profiles viewer
      where viewer.id=auth.uid()
        and (viewer.role='admin' or viewer.is_financing_operator)
    )
  );
create policy "Financing documents follow process visibility"
  on public.crm_financing_documents for select
  using (public.can_view_financing(process_id));
create policy "Financing conformity follows process visibility"
  on public.crm_financing_conformity_attempts for select
  using (public.can_view_financing(process_id));
create policy "Financing history follows process visibility"
  on public.crm_financing_history for select
  using (public.can_view_financing(process_id));

create or replace function public.can_read_financing_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select public.is_financing_operator()
    and exists (
      select 1 from public.crm_financing_processes process
      where process.broker_id=p_profile_id or process.operator_id=p_profile_id
    );
$$;

revoke all on function public.can_read_financing_profile(uuid) from public, anon;
grant execute on function public.can_read_financing_profile(uuid) to authenticated, service_role;

create policy "Financing operators read participating profiles"
  on public.profiles for select
  using (public.can_read_financing_profile(id));

create policy "Financing operators read financed leads"
  on public.crm_leads for select
  using (
    exists (
      select 1 from public.profiles viewer
      where viewer.id=auth.uid() and viewer.is_financing_operator
    )
    and exists (
      select 1 from public.crm_financing_processes process
      where process.lead_id=crm_leads.id
    )
  );

create or replace function public.crm_financing_add_history(
  p_process_id uuid,
  p_stage text,
  p_action text,
  p_field_name text default null,
  p_old_value jsonb default null,
  p_new_value jsonb default null,
  p_note text default null,
  p_attempt_number integer default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  process_lead_id uuid;
  actor_name_value text;
begin
  select process.lead_id into process_lead_id
  from public.crm_financing_processes process where process.id = p_process_id;
  select coalesce(nullif(profile.full_name,''), profile.email, 'Usuario') into actor_name_value
  from public.profiles profile where profile.id = auth.uid();
  insert into public.crm_financing_history(
    process_id, lead_id, stage, action, field_name, old_value, new_value,
    actor_id, actor_name, note, attempt_number
  ) values (
    p_process_id, process_lead_id, p_stage, p_action, p_field_name, p_old_value, p_new_value,
    auth.uid(), coalesce(actor_name_value, 'Usuario'), nullif(btrim(p_note),''), p_attempt_number
  );
end;
$$;

revoke all on function public.crm_financing_add_history(uuid,text,text,text,jsonb,jsonb,text,integer)
  from public, anon, authenticated;

create or replace function public.start_lead_financing(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  viewer public.profiles%rowtype;
  operator_user_id uuid;
  process_id_value uuid;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select * into viewer from public.profiles where id = auth.uid();
  select * into lead_record from public.crm_leads where id = p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;
  if viewer.role <> 'admin' and lead_record.owner_id <> auth.uid() then
    raise exception 'Somente o corretor responsavel pode marcar este lead como financiamento.';
  end if;
  select profile.id into operator_user_id
  from public.profiles profile
  where profile.is_financing_operator
  order by case when lower(profile.email) = 'unassigned-operator@example.invalid' then 0 else 1 end,
           profile.created_at
  limit 1;
  if operator_user_id is null then
    raise exception 'Nenhum operador de financiamento esta configurado.';
  end if;

  insert into public.crm_financing_processes(
    lead_id, broker_id, operator_id, activated_by
  ) values (
    lead_record.id, lead_record.owner_id, operator_user_id, auth.uid()
  )
  on conflict (lead_id) do nothing
  returning id into process_id_value;

  if process_id_value is null then
    select process.id into process_id_value
    from public.crm_financing_processes process where process.lead_id = p_lead_id;
    return process_id_value;
  end if;

  insert into public.crm_financing_documents(process_id, document_key, label, position)
  values
    (process_id_value, 'identification', 'Documento de identificação', 1),
    (process_id_value, 'civil_status', 'Documentação de estado civil', 2),
    (process_id_value, 'residence', 'Comprovante de residência', 3),
    (process_id_value, 'income', 'Comprovantes de renda', 4),
    (process_id_value, 'bank_statements', 'Extratos bancarios', 5),
    (process_id_value, 'income_tax', 'Declaração de Imposto de Renda', 6),
    (process_id_value, 'property', 'Documentação do imóvel', 7);

  perform public.crm_financing_add_history(
    process_id_value, 'checklist', 'financing_started', 'lead_id', null,
    to_jsonb(p_lead_id), 'Lead marcado como financiamento pelo corretor responsavel.'
  );

  insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
  select profile.id,
         'financing_new',
         'Novo financiamento recebido',
         'O lead ' || lead_record.name || ' entrou no fluxo. Confirme o envio do checklist.',
         '/financiamento?process=' || process_id_value,
         jsonb_build_object(
           'processId', process_id_value,
           'leadId', lead_record.id,
           'brokerId', lead_record.owner_id,
           'action', 'checklist_sent',
           'processVersion', 1
         )
  from public.profiles profile
  where profile.is_financing_operator;

  return process_id_value;
end;
$$;

revoke all on function public.start_lead_financing(uuid) from public, anon;
grant execute on function public.start_lead_financing(uuid) to authenticated;

create or replace function public.update_financing_process(
  p_process_id uuid,
  p_action text,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version bigint default null,
  p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  process_record public.crm_financing_processes%rowtype;
  viewer public.profiles%rowtype;
  old_value jsonb;
  new_value jsonb;
  action_stage text;
  attempt_record public.crm_financing_conformity_attempts%rowtype;
  attempt_no integer;
  document_record public.crm_financing_documents%rowtype;
  selected_boolean boolean;
  selected_date date;
  selected_number numeric;
  selected_text text;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select * into viewer from public.profiles where id = auth.uid();
  if viewer.role <> 'admin' and not viewer.is_financing_operator then
    raise exception 'Somente o operador de financiamento pode alterar este processo.';
  end if;
  select * into process_record
  from public.crm_financing_processes process
  where process.id = p_process_id for update;
  if not found then raise exception 'Financiamento nao encontrado.'; end if;
  if p_expected_version is not null and process_record.version <> p_expected_version then
    raise exception 'Este financiamento foi alterado em outra tela. Atualize e tente novamente.';
  end if;

  action_stage := process_record.current_stage;

  if p_action = 'checklist_sent' then
    selected_boolean := (p_payload->>'sent')::boolean;
    if selected_boolean is null then raise exception 'Informe se o checklist foi enviado.'; end if;
    if process_record.current_stage <> 'checklist' then
      raise exception 'O checklist inicial ja foi concluido.';
    end if;
    old_value := to_jsonb(process_record.checklist_sent);
    update public.crm_financing_processes set
      checklist_sent = selected_boolean,
      checklist_sent_at = case when selected_boolean then now() else null end,
      checklist_sent_by = case when selected_boolean then auth.uid() else null end
    where id = p_process_id;
    new_value := to_jsonb(selected_boolean);

  elsif p_action = 'document_status' then
    if process_record.documentation_complete then
      raise exception 'A documentacao ja foi concluida.';
    end if;
    select * into document_record
    from public.crm_financing_documents document
    where document.id = (p_payload->>'document_id')::uuid
      and document.process_id = p_process_id for update;
    if not found then raise exception 'Documento nao encontrado.'; end if;
    selected_text := p_payload->>'status';
    if selected_text not in ('pending','received') then raise exception 'Status de documento invalido.'; end if;
    old_value := jsonb_build_object('id',document_record.id,'status',document_record.status);
    update public.crm_financing_documents set
      status = selected_text,
      received_at = case when selected_text='received' then now() else null end,
      received_by = case when selected_text='received' then auth.uid() else null end
    where id = document_record.id;
    new_value := jsonb_build_object('id',document_record.id,'label',document_record.label,'status',selected_text);

  elsif p_action = 'documentation_complete' then
    selected_boolean := (p_payload->>'complete')::boolean;
    if selected_boolean is null then raise exception 'Informe se a documentacao esta completa.'; end if;
    if selected_boolean and exists (
      select 1 from public.crm_financing_documents
      where process_id=p_process_id and status<>'received'
    ) then raise exception 'Receba todos os documentos antes de concluir o checklist.'; end if;
    if process_record.current_stage not in ('documentation','checklist') then
      raise exception 'A etapa de documentacao ja foi encerrada.';
    end if;
    old_value := to_jsonb(process_record.documentation_complete);
    update public.crm_financing_processes set
      documentation_complete=selected_boolean,
      documentation_completed_at=case when selected_boolean then now() else null end,
      documentation_completed_by=case when selected_boolean then auth.uid() else null end
    where id=p_process_id;
    new_value := to_jsonb(selected_boolean);

  elsif p_action = 'credit_decision' then
    if not process_record.documentation_complete then raise exception 'Conclua a documentacao primeiro.'; end if;
    if process_record.current_stage <> 'credit' then raise exception 'A decisao de credito nao esta disponivel nesta etapa.'; end if;
    selected_boolean := (p_payload->>'approved')::boolean;
    if selected_boolean is null then raise exception 'Informe a decisao do credito.'; end if;
    selected_number := nullif(p_payload->>'approved_value','')::numeric;
    selected_text := nullif(btrim(p_payload->>'reason'),'');
    if selected_boolean and coalesce(selected_number,0)<=0 then raise exception 'Informe o valor aprovado.'; end if;
    if not selected_boolean and selected_text is null then raise exception 'Informe o motivo da negativa.'; end if;
    old_value := jsonb_build_object('approved',process_record.credit_approved,'value',process_record.credit_approved_value,'reason',process_record.credit_denial_reason);
    update public.crm_financing_processes set
      credit_approved=selected_boolean,
      credit_approved_value=case when selected_boolean then selected_number else null end,
      credit_denial_reason=case when not selected_boolean then selected_text else null end,
      credit_decided_at=now(), credit_decided_by=auth.uid()
    where id=p_process_id;
    new_value := jsonb_build_object('approved',selected_boolean,'value',selected_number,'reason',selected_text);

  elsif p_action = 'inspection_request' then
    if process_record.credit_approved is distinct from true then raise exception 'O credito precisa estar aprovado.'; end if;
    if process_record.current_stage <> 'inspection' then raise exception 'O pedido de vistoria nao esta disponivel nesta etapa.'; end if;
    selected_boolean := (p_payload->>'requested')::boolean;
    if selected_boolean is null then raise exception 'Informe se a vistoria foi solicitada.'; end if;
    old_value := to_jsonb(process_record.inspection_requested);
    update public.crm_financing_processes set inspection_requested=selected_boolean,
      inspection_requested_at=now(), inspection_requested_by=auth.uid() where id=p_process_id;
    new_value := to_jsonb(selected_boolean);

  elsif p_action = 'report_result' then
    if process_record.inspection_requested is distinct from true then raise exception 'Registre o pedido de vistoria primeiro.'; end if;
    if process_record.current_stage <> 'report' then raise exception 'O laudo nao esta disponivel nesta etapa.'; end if;
    selected_text := p_payload->>'result';
    selected_number := nullif(p_payload->>'property_value','')::numeric;
    if selected_text not in ('approved','denied') then raise exception 'Resultado do laudo invalido.'; end if;
    if selected_text='approved' and coalesce(selected_number,0)<=0 then raise exception 'Informe o valor da avaliacao.'; end if;
    if selected_text='denied' and nullif(btrim(p_payload->>'reason'),'') is null then raise exception 'Informe o motivo da negativa.'; end if;
    old_value := jsonb_build_object('result',process_record.report_result,'value',process_record.report_property_value,'reason',process_record.report_denial_reason);
    update public.crm_financing_processes set report_result=selected_text,
      report_property_value=case when selected_text='approved' then selected_number else null end,
      report_denial_reason=case when selected_text='denied' then nullif(btrim(p_payload->>'reason'),'') else null end,
      report_received_at=now(), report_received_by=auth.uid() where id=p_process_id;
    new_value := jsonb_build_object('result',selected_text,'value',selected_number,'reason',p_payload->>'reason');

  elsif p_action = 'conformity_start' then
    if process_record.report_result <> 'approved' then raise exception 'O laudo precisa estar aprovado.'; end if;
    selected_date := (p_payload->>'entry_date')::date;
    select * into attempt_record from public.crm_financing_conformity_attempts
      where process_id=p_process_id and active for update;
    if found and attempt_record.result is not null then raise exception 'Reinicie a conformidade para criar uma nova tentativa.'; end if;
    if found then
      old_value := to_jsonb(attempt_record.entry_date);
      update public.crm_financing_conformity_attempts set entry_date=selected_date where id=attempt_record.id;
      attempt_no := attempt_record.attempt_number;
    else
      select coalesce(max(attempt_number),0)+1 into attempt_no
      from public.crm_financing_conformity_attempts where process_id=p_process_id;
      insert into public.crm_financing_conformity_attempts(process_id,attempt_number,entry_date,started_by)
      values(p_process_id,attempt_no,selected_date,auth.uid());
      old_value := null;
    end if;
    new_value := to_jsonb(selected_date);

  elsif p_action = 'conformity_result' then
    select * into attempt_record from public.crm_financing_conformity_attempts
      where process_id=p_process_id and active for update;
    if not found or attempt_record.entry_date is null then raise exception 'Informe a data de entrada da conformidade.'; end if;
    selected_text := p_payload->>'result';
    if selected_text not in ('conform','nonconform') then raise exception 'Resultado de conformidade invalido.'; end if;
    selected_date := nullif(p_payload->>'return_date','')::date;
    if selected_text='conform' and selected_date is null then raise exception 'Informe a data de retorno da conformidade.'; end if;
    if selected_text='nonconform' and nullif(btrim(p_payload->>'reason'),'') is null then raise exception 'Informe o motivo da inconformidade.'; end if;
    old_value := jsonb_build_object('result',attempt_record.result,'return_date',attempt_record.return_date,'reason',attempt_record.nonconformity_reason);
    update public.crm_financing_conformity_attempts set result=selected_text,
      return_date=case when selected_text='conform' then selected_date else null end,
      nonconformity_reason=case when selected_text='nonconform' then nullif(btrim(p_payload->>'reason'),'') else null end,
      decided_at=now(),decided_by=auth.uid() where id=attempt_record.id;
    attempt_no := attempt_record.attempt_number;
    new_value := jsonb_build_object('result',selected_text,'return_date',selected_date,'reason',p_payload->>'reason');

  elsif p_action = 'conformity_restart' then
    select * into attempt_record from public.crm_financing_conformity_attempts
      where process_id=p_process_id and active for update;
    if not found or attempt_record.result <> 'nonconform' then raise exception 'Somente uma conformidade inconforme pode ser reiniciada.'; end if;
    old_value := jsonb_build_object('attempt',attempt_record.attempt_number,'result',attempt_record.result);
    update public.crm_financing_conformity_attempts set active=false,restarted_at=now(),restarted_by=auth.uid()
      where id=attempt_record.id;
    attempt_no := attempt_record.attempt_number+1;
    insert into public.crm_financing_conformity_attempts(process_id,attempt_number,started_by)
      values(p_process_id,attempt_no,auth.uid());
    new_value := jsonb_build_object('attempt',attempt_no,'result',null);

  elsif p_action = 'committee_date' then
    if process_record.current_stage <> 'committee' then raise exception 'O comite nao esta disponivel nesta etapa.'; end if;
    if not exists (select 1 from public.crm_financing_conformity_attempts where process_id=p_process_id and active and result='conform' and return_date is not null)
      then raise exception 'Conclua a conformidade primeiro.'; end if;
    selected_date := (p_payload->>'date')::date;
    old_value := to_jsonb(process_record.committee_sent_date);
    update public.crm_financing_processes set committee_sent_date=selected_date,
      committee_recorded_at=now(),committee_recorded_by=auth.uid() where id=p_process_id;
    new_value := to_jsonb(selected_date);

  elsif p_action = 'minutes_issued' then
    if process_record.current_stage <> 'minutes' then raise exception 'A minuta nao esta disponivel nesta etapa.'; end if;
    if process_record.committee_sent_date is null then raise exception 'Informe o envio ao comite primeiro.'; end if;
    old_value := to_jsonb(process_record.minutes_issued);
    update public.crm_financing_processes set minutes_issued=true,minutes_issued_at=now(),minutes_issued_by=auth.uid() where id=p_process_id;
    new_value := 'true'::jsonb;

  elsif p_action = 'notary_complete' then
    if process_record.current_stage <> 'notary' then raise exception 'O Cartorio de Notas nao esta disponivel nesta etapa.'; end if;
    if not process_record.minutes_issued then raise exception 'Registre a emissao da minuta primeiro.'; end if;
    selected_text := nullif(btrim(p_payload->>'notary_name'),'');
    if selected_text is null or nullif(p_payload->>'deed_date','') is null or nullif(p_payload->>'signing_date','') is null
      then raise exception 'Preencha todos os campos do Cartorio de Notas.'; end if;
    old_value := jsonb_build_object('notary_name',process_record.notary_name,'deed_date',process_record.deed_date,'signing_date',process_record.deed_signing_date);
    update public.crm_financing_processes set notary_name=selected_text,
      deed_date=(p_payload->>'deed_date')::date,deed_signing_date=(p_payload->>'signing_date')::date,
      notary_completed_at=now(),notary_completed_by=auth.uid(),
      registry_opened_at=coalesce(registry_opened_at,now()) where id=p_process_id;
    new_value := jsonb_build_object('notary_name',selected_text,'deed_date',p_payload->>'deed_date','signing_date',p_payload->>'signing_date');

  elsif p_action = 'registry_details' then
    if process_record.current_stage <> 'registry_details' then raise exception 'O registro nao esta disponivel nesta etapa.'; end if;
    if process_record.registry_opened_at is null then raise exception 'Conclua o Cartorio de Notas primeiro.'; end if;
    selected_text := nullif(btrim(p_payload->>'protocol'),'');
    selected_date := nullif(p_payload->>'expected_delivery','')::date;
    if selected_text is null or selected_date is null then raise exception 'Informe protocolo e previsao de entrega.'; end if;
    old_value := jsonb_build_object('protocol',process_record.registry_protocol,'expected_delivery',process_record.registry_expected_delivery);
    update public.crm_financing_processes set registry_protocol=selected_text,
      registry_expected_delivery=selected_date,registry_details_completed_at=now(),
      registry_details_completed_by=auth.uid(),registry_phase=coalesce(registry_phase,'examination'),
      registry_phase_updated_at=coalesce(registry_phase_updated_at,now()),
      registry_phase_updated_by=coalesce(registry_phase_updated_by,auth.uid()) where id=p_process_id;
    new_value := jsonb_build_object('protocol',selected_text,'expected_delivery',selected_date);

  elsif p_action = 'registry_phase' then
    if process_record.registry_details_completed_at is null then raise exception 'Preencha protocolo e previsao de entrega primeiro.'; end if;
    selected_text := p_payload->>'phase';
    if selected_text not in ('examination','registering','ready') then raise exception 'Fase de registro invalida.'; end if;
    old_value := to_jsonb(process_record.registry_phase);
    update public.crm_financing_processes set registry_phase=selected_text,
      registry_phase_updated_at=now(),registry_phase_updated_by=auth.uid() where id=p_process_id;
    new_value := to_jsonb(selected_text);

  elsif p_action = 'release_entry' then
    if process_record.current_stage <> 'release_conformity' then raise exception 'A liberacao de credito nao esta disponivel nesta etapa.'; end if;
    if process_record.registry_phase <> 'ready' then raise exception 'O registro precisa estar pronto.'; end if;
    selected_date := (p_payload->>'entry_date')::date;
    old_value := to_jsonb(process_record.release_conformity_entry_date);
    update public.crm_financing_processes set release_conformity_entry_date=selected_date where id=p_process_id;
    new_value := to_jsonb(selected_date);

  elsif p_action = 'release_decision' then
    if process_record.current_stage <> 'release_conformity' then raise exception 'A liberacao de credito nao esta disponivel nesta etapa.'; end if;
    if process_record.release_conformity_entry_date is null then raise exception 'Informe a entrada da conformidade de liberacao.'; end if;
    selected_boolean := (p_payload->>'conform')::boolean;
    if selected_boolean is null then raise exception 'Informe o resultado da liberacao.'; end if;
    selected_date := nullif(p_payload->>'credit_release_date','')::date;
    selected_text := nullif(btrim(p_payload->>'reason'),'');
    if selected_boolean and selected_date is null then raise exception 'Informe a data da liberacao do credito.'; end if;
    if not selected_boolean and selected_text is null then raise exception 'Informe o motivo da nao conformidade.'; end if;
    old_value := jsonb_build_object('conform',process_record.release_conform,'credit_release_date',process_record.credit_release_date,'reason',process_record.release_denial_reason);
    update public.crm_financing_processes set release_conform=selected_boolean,
      credit_release_date=case when selected_boolean then selected_date else null end,
      release_denial_reason=case when not selected_boolean then selected_text else null end,
      release_decided_at=now(),release_decided_by=auth.uid(),
      completed_at=case when selected_boolean then now() else null end,
      completed_by=case when selected_boolean then auth.uid() else null end where id=p_process_id;
    new_value := jsonb_build_object('conform',selected_boolean,'credit_release_date',selected_date,'reason',selected_text);
  else
    raise exception 'Acao de financiamento invalida.';
  end if;

  -- Deriva etapa e status somente dos requisitos persistidos.
  update public.crm_financing_processes process set
    current_stage = case
      when process.completed_at is not null then 'completed'
      when process.registry_phase='ready' then 'release_conformity'
      when process.registry_details_completed_at is not null then 'registry_phase'
      when process.registry_opened_at is not null then 'registry_details'
      when process.notary_completed_at is null and process.minutes_issued then 'notary'
      when not process.minutes_issued and process.committee_sent_date is not null then 'minutes'
      when process.committee_sent_date is null and exists (
        select 1 from public.crm_financing_conformity_attempts attempt
        where attempt.process_id=process.id and attempt.active and attempt.result='conform' and attempt.return_date is not null
      ) then 'committee'
      when process.report_result='approved' then 'conformity'
      when process.inspection_requested is true then 'report'
      when process.credit_approved is true then 'inspection'
      when process.documentation_complete then 'credit'
      when process.checklist_sent then 'documentation'
      else 'checklist'
    end,
    status = case
      when process.completed_at is not null then 'completed'
      when process.release_conform is false then 'release_nonconform'
      when process.credit_approved is false then 'credit_denied'
      when process.report_result='denied' then 'report_denied'
      when process.inspection_requested is false then 'inspection_not_requested'
      when process.registry_opened_at is not null then 'awaiting_registry'
      when process.report_result='approved' then 'awaiting_conformity'
      when not process.documentation_complete then 'awaiting_documents'
      when process.checklist_sent then 'in_progress'
      else 'pending'
    end,
    version=process.version+1
  where process.id=p_process_id
  returning process.version into p_expected_version;

  perform public.crm_financing_add_history(
    p_process_id, action_stage, p_action, p_action, old_value, new_value,
    p_note, attempt_no
  );
  return p_expected_version;
end;
$$;

revoke all on function public.update_financing_process(uuid,text,jsonb,bigint,text) from public, anon;
grant execute on function public.update_financing_process(uuid,text,jsonb,bigint,text) to authenticated;

comment on table public.crm_financing_processes is
  'Processos operacionais de financiamento vinculados a leads, sem alterar o fluxo comercial original.';
comment on table public.crm_financing_history is
  'Auditoria append-only. Escrita somente pelas funcoes transacionais do modulo.';
