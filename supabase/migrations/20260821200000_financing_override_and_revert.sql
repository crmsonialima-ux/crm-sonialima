begin;

alter table public.crm_financing_processes
  add column if not exists credit_financing_value numeric(14,2);

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
  is_override boolean := false;
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
  selected_financing_value numeric;
  selected_text text;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  select * into viewer from public.profiles where id = auth.uid();
  
  -- APENAS Allyson e Vitor podem alterar o financiamento
  if lower(viewer.email) not in ('crmsoniaallyson@gmail.com', 'unassigned-operator@example.invalid') then
    raise exception 'Somente Allyson e Vitor podem alterar dados do financiamento.';
  end if;

  is_override := true;

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
    if not is_override and process_record.current_stage <> 'checklist' then
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
    -- Removida a exigÃªncia de todos os documentos recebidos.
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
    if not process_record.documentation_complete then raise exception 'Conclua a documentaÃ§Ã£o primeiro.'; end if;
    if not is_override and process_record.current_stage <> 'credit' then raise exception 'A decisÃ£o de crÃ©dito nÃ£o estÃ¡ disponÃ­vel nesta etapa.'; end if;
    selected_boolean := (p_payload->>'approved')::boolean;
    if selected_boolean is null then raise exception 'Informe a decisÃ£o do crÃ©dito.'; end if;
    
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

  elsif p_action = 'inspection_checklist' then
    if not is_override and process_record.credit_approved is distinct from true then raise exception 'O credito precisa estar aprovado.'; end if;
    if not is_override and process_record.current_stage <> 'inspection' then raise exception 'O checklist de vistoria nao esta disponivel nesta etapa.'; end if;
    
    old_value := process_record.inspection_checklist;
    update public.crm_financing_processes set
      inspection_checklist = process_record.inspection_checklist || p_payload
    where id = p_process_id;
    new_value := process_record.inspection_checklist || p_payload;

  elsif p_action = 'inspection_request' then
    if not is_override and process_record.credit_approved is distinct from true then raise exception 'O credito precisa estar aprovado.'; end if;
    if not is_override and process_record.current_stage <> 'inspection' then raise exception 'O pedido de vistoria nao esta disponivel nesta etapa.'; end if;
    selected_boolean := (p_payload->>'requested')::boolean;
    if selected_boolean is null then raise exception 'Informe se a vistoria foi solicitada.'; end if;
    old_value := to_jsonb(process_record.inspection_requested);
    update public.crm_financing_processes set inspection_requested=selected_boolean,
      inspection_requested_at=now(), inspection_requested_by=auth.uid() where id=p_process_id;
    new_value := to_jsonb(selected_boolean);

  elsif p_action = 'report_result' then
    if not is_override and process_record.inspection_requested is distinct from true then raise exception 'Registre o pedido de vistoria primeiro.'; end if;
    if not is_override and process_record.current_stage <> 'report' then raise exception 'O laudo nao esta disponivel nesta etapa.'; end if;
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
    if not is_override and process_record.report_result <> 'approved' then raise exception 'O laudo precisa estar aprovado.'; end if;
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
    selected_financing_value := nullif(p_payload->>'financing_value','')::numeric;
    if selected_text='conform' and selected_date is null then raise exception 'Informe a data de retorno da conformidade.'; end if;
    if selected_text='conform' and coalesce(selected_financing_value,0)<=0 then raise exception 'Informe o valor do financiamento.'; end if;
    if selected_text='nonconform' and nullif(btrim(p_payload->>'reason'),'') is null then raise exception 'Informe o motivo da inconformidade.'; end if;
    old_value := jsonb_build_object('result',attempt_record.result,'return_date',attempt_record.return_date,'reason',attempt_record.nonconformity_reason);
    update public.crm_financing_conformity_attempts set result=selected_text,
      return_date=case when selected_text='conform' then selected_date else null end,
      nonconformity_reason=case when selected_text='nonconform' then nullif(btrim(p_payload->>'reason'),'') else null end,
      decided_at=now(),decided_by=auth.uid() where id=attempt_record.id;
    if selected_text='conform' then
      update public.crm_financing_processes set credit_financing_value=selected_financing_value where id=p_process_id;
    end if;
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
    if not is_override and process_record.current_stage <> 'committee' then raise exception 'O comite nao esta disponivel nesta etapa.'; end if;
    if not exists (select 1 from public.crm_financing_conformity_attempts where process_id=p_process_id and active and result='conform' and return_date is not null)
      then raise exception 'Conclua a conformidade primeiro.'; end if;
    selected_date := (p_payload->>'date')::date;
    old_value := to_jsonb(process_record.committee_sent_date);
    update public.crm_financing_processes set committee_sent_date=selected_date,
      committee_recorded_at=now(),committee_recorded_by=auth.uid() where id=p_process_id;
    new_value := to_jsonb(selected_date);

  elsif p_action = 'minutes_issued' then
    if not is_override and process_record.current_stage <> 'minutes' then raise exception 'A minuta nao esta disponivel nesta etapa.'; end if;
    if process_record.committee_sent_date is null then raise exception 'Informe o envio ao comite primeiro.'; end if;
    old_value := to_jsonb(process_record.minutes_issued);
    update public.crm_financing_processes set minutes_issued=true,minutes_issued_at=now(),minutes_issued_by=auth.uid() where id=p_process_id;
    new_value := 'true'::jsonb;

  elsif p_action = 'notary_complete' then
    if not is_override and process_record.current_stage <> 'notary' then raise exception 'O Cartorio de Notas nao esta disponivel nesta etapa.'; end if;
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
    if not is_override and process_record.current_stage <> 'registry_details' then raise exception 'O registro nao esta disponivel nesta etapa.'; end if;
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
    if not is_override and process_record.current_stage <> 'release_conformity' then raise exception 'A liberacao de credito nao esta disponivel nesta etapa.'; end if;
    if process_record.registry_phase <> 'ready' then raise exception 'O registro precisa estar pronto.'; end if;
    selected_date := (p_payload->>'entry_date')::date;
    old_value := to_jsonb(process_record.release_conformity_entry_date);
    update public.crm_financing_processes set release_conformity_entry_date=selected_date where id=p_process_id;
    new_value := to_jsonb(selected_date);

  elsif p_action = 'release_decision' then
    if not is_override and process_record.current_stage <> 'release_conformity' then raise exception 'A liberacao de credito nao esta disponivel nesta etapa.'; end if;
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
elsif p_action = 'revert_to_stage' then
    selected_text := p_payload->>'target_stage';
    
    if not is_override then raise exception 'Voce nao tem permissao para reverter etapas.'; end if;

    if selected_text = 'checklist' then
      update public.crm_financing_processes set checklist_sent = false, checklist_sent_at = null, checklist_sent_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation') then
      update public.crm_financing_processes set documentation_complete = false, documentation_completed_at = null, documentation_completed_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit') then
      update public.crm_financing_processes set credit_approved = null, credit_approved_value = null, credit_denial_reason = null, credit_decided_at = null, credit_decided_by = null, credit_financing_value = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection') then
      update public.crm_financing_processes set inspection_requested = null, inspection_requested_at = null, inspection_requested_by = null, inspection_checklist = '{}'::jsonb where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report') then
      update public.crm_financing_processes set report_result = null, report_property_value = null, report_denial_reason = null, report_received_at = null, report_received_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity') then
      update public.crm_financing_conformity_attempts set active = false where process_id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity', 'committee') then
      update public.crm_financing_processes set committee_sent_date = null, committee_recorded_at = null, committee_recorded_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity', 'committee', 'minutes') then
      update public.crm_financing_processes set minutes_issued = false, minutes_issued_at = null, minutes_issued_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity', 'committee', 'minutes', 'notary') then
      update public.crm_financing_processes set notary_completed_at = null, notary_completed_by = null, notary_name = null, deed_date = null, deed_signing_date = null, registry_opened_at = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity', 'committee', 'minutes', 'notary', 'registry_details') then
      update public.crm_financing_processes set registry_protocol = null, registry_expected_delivery = null, registry_details_completed_at = null, registry_details_completed_by = null, registry_phase = null, registry_phase_updated_at = null, registry_phase_updated_by = null where id = p_process_id;
    end if;
    if selected_text in ('checklist', 'documentation', 'credit', 'inspection', 'report', 'conformity', 'committee', 'minutes', 'notary', 'registry_details', 'registry_phase', 'release_conformity') then
      update public.crm_financing_processes set release_conformity_entry_date = null, release_conform = null, credit_release_date = null, release_denial_reason = null, release_decided_at = null, release_decided_by = null, completed_at = null, completed_by = null where id = p_process_id;
    end if;
    
    old_value := null;
    new_value := to_jsonb(selected_text);
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

commit;
