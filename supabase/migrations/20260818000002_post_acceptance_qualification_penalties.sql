begin;

alter table public.crm_leads
  add column if not exists post_acceptance_whatsapp_has_whatsapp boolean;

alter table public.profiles
  add column if not exists lead_distribution_blocked_until timestamptz;

-- Update the qualification completion logic to enforce the new 5h blocking rules and 24h timer logic.
create or replace function public.save_post_acceptance_lead_qualification(
  p_lead_id uuid,
  p_call_made boolean,
  p_call_result text default null,
  p_interaction text default null,
  p_whatsapp boolean default null,
  p_print_path text default null,
  p_has_whatsapp boolean default null
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  lead public.crm_leads%rowtype;
  actor record;
  complete boolean := false;
  penalize_5h boolean := false;
begin
 select * into lead from public.crm_leads where id=p_lead_id for update;
 if not found or lead.owner_id<>auth.uid() or lead.assignment_status<>'accepted' or lead.post_acceptance_qualification_expired_at is not null or lead.post_acceptance_qualification_deadline_at<=now() then raise exception 'O prazo de qualificacao deste lead terminou ou ele nao esta mais atribuido a voce.'; end if;
 if lead.post_acceptance_qualification_completed_at is not null then raise exception 'A qualificacao ja foi concluida e nao pode ser alterada.'; end if;

 -- Validation Logic
 if p_call_made then
   if p_call_result not in ('Falou com o cliente', 'Não atendeu') then raise exception 'Informe o resultado da ligacao (Falou com o cliente ou Não atendeu).'; end if;
   if p_call_result = 'Falou com o cliente' and nullif(trim(coalesce(p_interaction,'')),'') is null then raise exception 'Descreva como foi a interacao.'; end if;
   if p_call_result = 'Não atendeu' and p_whatsapp is null then raise exception 'Informe se chamou no WhatsApp.'; end if;
   if p_call_result = 'Não atendeu' and p_whatsapp = true and nullif(p_print_path,'') is null then raise exception 'Anexe o print da tentativa no WhatsApp.'; end if;
   if p_call_result = 'Não atendeu' and p_whatsapp = false and p_has_whatsapp is null then raise exception 'Informe se o cliente possui WhatsApp.'; end if;
 end if;

 select full_name,email into actor from public.profiles where id=auth.uid();

 if lead.post_acceptance_call_made = true and p_call_made = false then raise exception 'Voce ja registrou que ligou para o cliente e nao pode alterar para Nao.'; end if;

 -- Evaluate Rules
 if p_call_made = false then
   if p_whatsapp = false then
     penalize_5h := true;
   elsif p_whatsapp = true and nullif(p_print_path,'') is null then
     raise exception 'Anexe o print da tentativa no WhatsApp.';
   elsif p_whatsapp = true and nullif(p_print_path,'') is not null then
     complete := true;
   else
     raise exception 'Informe se chamou no WhatsApp.';
   end if;
 else
   if p_call_result = 'Falou com o cliente' and nullif(trim(coalesce(p_interaction,'')),'') is not null then
     complete := true;
   elsif p_call_result = 'Não atendeu' and p_whatsapp = true and nullif(p_print_path,'') is not null then
     complete := true;
   elsif p_call_result = 'Não atendeu' and p_whatsapp = false then
     if p_has_whatsapp = true then
       penalize_5h := true;
     elsif p_has_whatsapp = false then
       complete := true;
     end if;
   end if;
 end if;

 -- Historical Logs
 if lead.post_acceptance_call_made is distinct from p_call_made then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: ligacao',case when p_call_made then 'Ja ligou para o cliente: Sim.' else 'Ja ligou para o cliente: Nao.' end,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 if p_call_made and lead.post_acceptance_call_result is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: resultado', 'Resultado da ligacao: '||p_call_result,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 if p_call_made and p_call_result = 'Falou com o cliente' and lead.post_acceptance_interaction is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: interacao',trim(p_interaction),auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 if p_whatsapp is not null and lead.post_acceptance_whatsapp_contacted is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: WhatsApp','Chamou no WhatsApp: '||case when p_whatsapp then 'Sim.' else 'Nao.' end,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 if p_whatsapp = true and p_print_path is not null and lead.post_acceptance_whatsapp_print_path is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: print','Print da tentativa no WhatsApp anexado.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 if p_has_whatsapp is not null and lead.post_acceptance_whatsapp_has_whatsapp is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: possui WhatsApp','O cliente possui WhatsApp? '||case when p_has_whatsapp then 'Sim.' else 'Nao.' end,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;

 -- Apply Penalty if rules mandate it
 if penalize_5h then
   -- Block Profile
   update public.profiles set 
     lead_distribution_blocked_until = now() + interval '5 hours',
     lead_distribution_blocked_reason = 'Penalidade: falta de tentativa mínima de contato'
   where id = auth.uid();
   
   -- Cancel reminders
   delete from public.crm_notification_outbox 
   where kind = 'qualification_reminder' and recipient_id = auth.uid() and payload->>'leadId' = p_lead_id::text and delivered_at is null;

   -- Return Lead to queue immediately
   update public.crm_leads set
     assignment_status = 'pending',
     assignment_deadline_at = now() - interval '1 second',
     assignment_available_at = now() - interval '1 second',
     stage = 'Aguardando atendimento',
     post_acceptance_call_made = coalesce(p_call_made, post_acceptance_call_made),
     post_acceptance_call_result = coalesce(p_call_result, post_acceptance_call_result),
     post_acceptance_interaction = coalesce(nullif(trim(p_interaction),''), post_acceptance_interaction),
     post_acceptance_whatsapp_contacted = coalesce(p_whatsapp, post_acceptance_whatsapp_contacted),
     post_acceptance_whatsapp_print_path = coalesce(nullif(p_print_path,''), post_acceptance_whatsapp_print_path),
     post_acceptance_whatsapp_has_whatsapp = coalesce(p_has_whatsapp, post_acceptance_whatsapp_has_whatsapp),
     post_acceptance_qualification_deadline_at = null,
     post_acceptance_qualification_completed_at = null,
     post_acceptance_qualification_expired_at = now()
   where id = p_lead_id;

   insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: Penalidade','Bloqueio de 5h aplicado por falta de tentativa minima de contato. Lead devolvido a fila.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email));
   
   -- Trigger redistribution logic instantly
   perform public.process_expired_lead_assignments();
   return;
 end if;

 -- Normal Completion update
 update public.crm_leads set
   post_acceptance_call_made = coalesce(p_call_made, post_acceptance_call_made),
   post_acceptance_call_result = coalesce(p_call_result, post_acceptance_call_result),
   post_acceptance_interaction = coalesce(nullif(trim(p_interaction),''), post_acceptance_interaction),
   post_acceptance_whatsapp_contacted = coalesce(p_whatsapp, post_acceptance_whatsapp_contacted),
   post_acceptance_whatsapp_print_path = coalesce(nullif(p_print_path,''), post_acceptance_whatsapp_print_path),
   post_acceptance_whatsapp_has_whatsapp = coalesce(p_has_whatsapp, post_acceptance_whatsapp_has_whatsapp),
   post_acceptance_qualification_completed_at = case when complete then now() else null end
 where id=p_lead_id;

 if complete then 
   -- Cancel any pending qualification reminders
   update public.crm_notification_outbox 
   set delivery_status = 'cancelled'
   where kind = 'qualification_reminder' and recipient_id = auth.uid() and payload->>'leadId' = p_lead_id::text and delivered_at is null;

   -- Begin 24h deadline clock exactly at completion time
   update public.crm_leads set
     assignment_deadline_at = now() + interval '24 hours'
   where id = p_lead_id;
   
   insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao concluida','Qualificacao obrigatoria apos o aceite concluida. Prazo de acompanhamento de 24 horas iniciado agora.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); 
 end if;
end $$;

-- Modification to `accept_lead_assignment` to insert the schedule of notifications
create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
begin
  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours', -- Overwritten on qualification complete, but acts as fallback if something goes wrong
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento',
      post_acceptance_qualification_deadline_at = now() + interval '2 hours',
      post_acceptance_call_made = null, post_acceptance_call_result = null, post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null, post_acceptance_whatsapp_print_path = null, post_acceptance_whatsapp_has_whatsapp = null,
      post_acceptance_qualification_completed_at = null, post_acceptance_qualification_expired_at = null
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and lead.assignment_available_at <= now()
    and lead.assignment_deadline_at > now()
    and public.crm_is_lead_queue_hours(now())
    and (
      lead.property_catalog_id is null
      or exists (
          select 1
          from public.crm_property_broker_access as access
          join public.lead_distribution_queue as queue
            on queue.broker_id = access.broker_id
           and queue.lead_type = lead.lead_type
          join public.profiles as profile
            on profile.id = access.broker_id
          where access.property_id = lead.property_catalog_id
            and access.broker_id = auth.uid()
            and profile.role = 'broker'
            and not coalesce(profile.lead_distribution_blocked, false)
            and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta disponivel para aceite neste horario, seu prazo/acesso foi alterado, ou voce esta temporariamente bloqueado.';
  end if;

  update public.lead_assignment_attempts as attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.run_number = accepted_run_number
    and attempt.notified_at <= now()
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  select profile.full_name, profile.email
  into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    p_lead_id,
    'Lead aceito',
    'Atendimento iniciado; qualificacao obrigatoria ate ' || to_char(now() at time zone 'America/Sao_Paulo' + interval '2 hours', 'DD/MM/YYYY HH24:MI') || '.',
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );

  -- Insert scheduled notifications
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at) values
    (auth.uid(),'qualification_reminder','Lead assumido — qualificação obrigatória','Você assumiu este lead. Conclua a qualificação obrigatória dentro de 2 horas. O prazo de acompanhamento de 24 horas começará após a conclusão correta da qualificação.','/leads',jsonb_build_object('leadId',p_lead_id),now()),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Restam aproximadamente 1h30 para concluir o atendimento obrigatório deste lead.','/leads',jsonb_build_object('leadId',p_lead_id),now() + interval '30 minutes'),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Resta aproximadamente 1 hora para concluir.','/leads',jsonb_build_object('leadId',p_lead_id),now() + interval '60 minutes'),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Atenção: faltam aproximadamente 30 minutos para o prazo da qualificação.','/leads',jsonb_build_object('leadId',p_lead_id),now() + interval '90 minutes');

end;
$$;

-- Extend distribution logic to exclude blocked brokers
-- We must update `create_distributed_lead`
create or replace function public.create_distributed_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_external_id text,
  p_lead_type text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  next_broker record;
  next_position integer;
  inserted_lead uuid;
  normalized_phone text;
begin
  if auth.uid() is null then
    raise exception 'Sessão não encontrada.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead inválido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then
    raise exception 'Telefone é obrigatório.';
  end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (
    select 1
    from public.crm_leads
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone
  ) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;

  select queue.broker_id, profile.full_name, profile.email
  into next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores ativos na fila de %.', p_lead_type;
  end if;

  select coalesce(max(position), 0) + 1
  into next_position
  from public.lead_distribution_queue
  where lead_type = p_lead_type;

  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes,
    owner_id, created_by, external_id, lead_type
  ) values (
    p_name, nullif(p_phone, ''), nullif(p_email, ''), nullif(p_property_interest, ''),
    p_stage, nullif(p_channel, ''), 0, nullif(p_notes, ''),
    next_broker.broker_id, auth.uid(), nullif(p_external_id, ''), p_lead_type
  ) returning id into inserted_lead;

  return query select
    inserted_lead,
    next_broker.broker_id,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

-- Also process_expired_lead_assignments needs to filter blocked brokers
create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row record;
  next_broker_id uuid;
  next_broker_name text;
  next_broker_email text;
  next_position integer;
  current_run integer;
  current_round smallint;
  attempt_count integer;
  next_attempt_number integer;
  next_duration_minutes integer;
  next_available_at timestamptz;
  next_deadline_at timestamptz;
  timeout_message text;
  source_label text;
begin
  if not public.crm_is_lead_queue_hours(now()) then
    return;
  end if;

  for lead_row in
    select lead.*
    from public.crm_leads as lead
    where lead.assignment_deadline_at <= now()
      and (
        lead.assignment_status = 'pending'
        or (
          lead.assignment_status = 'accepted'
          and lead.stage = 'Em atendimento'
        )
      )
    order by lead.assignment_deadline_at, lead.id
    for update skip locked
  loop
    update public.lead_assignment_attempts as attempt
    set expired_at = now()
    where attempt.lead_id = lead_row.id
      and attempt.broker_id = lead_row.owner_id
      and attempt.run_number = lead_row.assignment_run_number
      and attempt.expired_at is null
      and attempt.accepted_at is null;

    current_run := coalesce(lead_row.assignment_run_number, 1);
    select coalesce(max(attempt_number), 0)
    into attempt_count
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run;

    select round_number
    into current_round
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run
    order by attempt_number desc
    limit 1;
    current_round := coalesce(current_round, 1::smallint);

    if lead_row.property_catalog_id is null then
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.lead_distribution_queue as queue
      join public.profiles as profile on profile.id = queue.broker_id
      where queue.lead_type = lead_row.lead_type
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = queue.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    else
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.crm_property_broker_access as access
      join public.lead_distribution_queue as queue
        on queue.broker_id = access.broker_id
       and queue.lead_type = lead_row.lead_type
      join public.profiles as profile on profile.id = access.broker_id
      where access.property_id = lead_row.property_catalog_id
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = access.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    end if;

    if next_broker_id is null and current_round = 1 then
      current_round := 2;
      
      if lead_row.property_catalog_id is null then
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.lead_distribution_queue as queue
        join public.profiles as profile on profile.id = queue.broker_id
        where queue.lead_type = lead_row.lead_type
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = queue.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      else
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.crm_property_broker_access as access
        join public.lead_distribution_queue as queue
          on queue.broker_id = access.broker_id
         and queue.lead_type = lead_row.lead_type
        join public.profiles as profile on profile.id = access.broker_id
        where access.property_id = lead_row.property_catalog_id
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = access.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      end if;
    end if;

    timeout_message := case
      when lead_row.assignment_status = 'pending' then 'Prazo de aceite expirado'
      when lead_row.assignment_status = 'accepted' and lead_row.stage = 'Em atendimento' then 'Atraso no atendimento'
      else 'Prazo esgotado'
    end;

    if next_broker_id is null then
      update public.crm_leads as l
      set assignment_status = 'exhausted',
          assignment_deadline_at = null,
          assignment_available_at = null,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando redistribuicao pelo Allyson'
      where l.id = lead_row.id;

      source_label := coalesce(
        nullif(lead_row.channel, ''),
        nullif(lead_row.external_id, ''),
        'Origem manual'
      );
      insert into public.crm_lead_activities(lead_id, stage, note, author_name)
      values(
        lead_row.id,
        'Distribuicao esgotada',
        timeout_message || '. Nao ha mais corretores elegiveis. Aguardando Allyson.',
        'Sistema'
      );
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      select
        p.id,
        'lead_assignment_exhausted',
        'Lead esgotado na distribuicao',
        lead_row.name || ' (' || source_label || ') passou por todos os corretores e retornou para a gerencia.',
        '/leads',
        jsonb_build_object('leadId', lead_row.id)
      from public.profiles as p
      where lower(trim(p.email)) in ('crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid');
      continue;
    end if;

    select coalesce(max(position), 0) + 1
    into next_position
    from public.lead_distribution_queue
    where lead_type = lead_row.lead_type;

    update public.lead_distribution_queue
    set position = next_position, updated_at = now()
    where lead_type = lead_row.lead_type and broker_id = next_broker_id;

    next_attempt_number := attempt_count + 1;
    next_duration_minutes := case
      when next_attempt_number between 1 and 3 then 20
      when next_attempt_number between 4 and 6 then 40
      else 60
    end;
    next_available_at := public.crm_next_lead_queue_moment(now());
    next_deadline_at := public.crm_add_lead_queue_minutes(next_available_at, next_duration_minutes);

    update public.crm_leads as l
    set owner_id = next_broker_id,
        assignment_status = 'pending',
        assignment_available_at = next_available_at,
        assignment_deadline_at = next_deadline_at,
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento'
    where l.id = lead_row.id;

    insert into public.lead_assignment_attempts (
      lead_id,
      broker_id,
      attempt_number,
      run_number,
      round_number,
      notified_at,
      deadline_at
    ) values (
      lead_row.id,
      next_broker_id,
      next_attempt_number,
      current_run,
      current_round,
      next_available_at,
      next_deadline_at
    );

    insert into public.crm_lead_activities(lead_id, stage, note, author_name)
    values(
      lead_row.id,
      'Lead redistribuido',
      timeout_message || '. Distribuido para ' || coalesce(nullif(next_broker_name, ''), next_broker_email) || ' (' || next_duration_minutes || ' min uteis).',
      'Sistema'
    );

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload,
      available_at
    ) values (
      next_broker_id,
      'lead_assignment',
      'Novo lead aguardando atendimento',
      'Voce tem ' || next_duration_minutes || ' minutos uteis para iniciar o atendimento de ' || lead_row.name || '.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'phone', lead_row.phone,
        'name', lead_row.name,
        'attemptNumber', next_attempt_number,
        'runNumber', current_run,
        'roundNumber', current_round,
        'availableAt', next_available_at,
        'deadlineAt', next_deadline_at
      ),
      next_available_at
    );
  end loop;
end;
$$;

commit;
