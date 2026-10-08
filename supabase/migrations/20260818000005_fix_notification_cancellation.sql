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

 -- Normal Completion
 if complete then
   update public.crm_leads set
     post_acceptance_call_made = coalesce(p_call_made, post_acceptance_call_made),
     post_acceptance_call_result = coalesce(p_call_result, post_acceptance_call_result),
     post_acceptance_interaction = coalesce(nullif(trim(p_interaction),''), post_acceptance_interaction),
     post_acceptance_whatsapp_contacted = coalesce(p_whatsapp, post_acceptance_whatsapp_contacted),
     post_acceptance_whatsapp_print_path = coalesce(nullif(p_print_path,''), post_acceptance_whatsapp_print_path),
     post_acceptance_whatsapp_has_whatsapp = coalesce(p_has_whatsapp, post_acceptance_whatsapp_has_whatsapp),
     post_acceptance_qualification_completed_at = now(),
     assignment_deadline_at = lead.assignment_deadline_at + (now() - lead.assignment_available_at) -- Reset deadline 24h
   where id = p_lead_id;
   
   -- Cancel reminders
   delete from public.crm_notification_outbox 
   where kind = 'qualification_reminder' and recipient_id = auth.uid() and payload->>'leadId' = p_lead_id::text and delivered_at is null;

   insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: Concluida','Qualificacao de 2h concluida com sucesso. Prazo de 24h ativado.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email));
 else
   update public.crm_leads set
     post_acceptance_call_made = coalesce(p_call_made, post_acceptance_call_made),
     post_acceptance_call_result = coalesce(p_call_result, post_acceptance_call_result),
     post_acceptance_interaction = coalesce(nullif(trim(p_interaction),''), post_acceptance_interaction),
     post_acceptance_whatsapp_contacted = coalesce(p_whatsapp, post_acceptance_whatsapp_contacted),
     post_acceptance_whatsapp_print_path = coalesce(nullif(p_print_path,''), post_acceptance_whatsapp_print_path),
     post_acceptance_whatsapp_has_whatsapp = coalesce(p_has_whatsapp, post_acceptance_whatsapp_has_whatsapp)
   where id = p_lead_id;
 end if;
end;
$$;
