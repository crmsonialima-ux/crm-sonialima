begin;

alter table public.crm_leads
  add column if not exists post_acceptance_qualification_deadline_at timestamptz,
  add column if not exists post_acceptance_call_made boolean,
  add column if not exists post_acceptance_call_result text,
  add column if not exists post_acceptance_interaction text,
  add column if not exists post_acceptance_whatsapp_contacted boolean,
  add column if not exists post_acceptance_whatsapp_print_path text,
  add column if not exists post_acceptance_qualification_completed_at timestamptz,
  add column if not exists post_acceptance_qualification_expired_at timestamptz;

-- The existing acceptance remains the single source of truth; its saved time starts
-- this independent, real-time two-hour qualification deadline.
create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor record; accepted_run_number integer;
begin
  update public.crm_leads lead set assignment_status='accepted',
    assignment_deadline_at=greatest(now(),lead.assignment_available_at)+interval '24 hours',
    assignment_available_at=null, assignment_reminder_sent_at=null, stage='Em atendimento',
    post_acceptance_qualification_deadline_at=now()+interval '2 hours',
    post_acceptance_call_made=null, post_acceptance_call_result=null, post_acceptance_interaction=null,
    post_acceptance_whatsapp_contacted=null, post_acceptance_whatsapp_print_path=null,
    post_acceptance_qualification_completed_at=null, post_acceptance_qualification_expired_at=null
  where lead.id=p_lead_id and lead.owner_id=auth.uid() and lead.assignment_status='pending'
    and lead.assignment_deadline_at>now()
  returning lead.assignment_run_number into accepted_run_number;
  if not found then raise exception 'Este lead nao esta disponivel para aceite ou seu prazo/acesso foi alterado.'; end if;
  update public.lead_assignment_attempts set accepted_at=now() where lead_id=p_lead_id and broker_id=auth.uid() and run_number=accepted_run_number and accepted_at is null and expired_at is null;
  select full_name,email into actor from public.profiles where id=auth.uid();
  insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values
    (p_lead_id,'Lead aceito','Atendimento iniciado; qualificacao obrigatoria ate '||to_char(now()+interval '2 hours','DD/MM/YYYY HH24:MI')||'.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email));
end $$;

create or replace function public.save_post_acceptance_lead_qualification(
  p_lead_id uuid,
  p_call_made boolean,
  p_call_result text default null,
  p_interaction text default null,
  p_whatsapp boolean default null,
  p_print_path text default null
)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare lead public.crm_leads%rowtype; actor record; complete boolean;
begin
 select * into lead from public.crm_leads where id=p_lead_id for update;
 if not found or lead.owner_id<>auth.uid() or lead.assignment_status<>'accepted' or lead.post_acceptance_qualification_expired_at is not null or lead.post_acceptance_qualification_deadline_at<=now() then raise exception 'O prazo de qualificacao deste lead terminou ou ele nao esta mais atribuido a voce.'; end if;
 if lead.post_acceptance_qualification_completed_at is not null then raise exception 'A qualificacao ja foi concluida e nao pode ser alterada.'; end if;

 if p_call_made then
   if p_call_result not in ('Falou com o cliente', 'Não atendeu') then raise exception 'Informe o resultado da ligacao (Falou com o cliente ou Não atendeu).'; end if;
   if p_call_result = 'Falou com o cliente' and nullif(trim(coalesce(p_interaction,'')),'') is null then raise exception 'Descreva como foi a interacao.'; end if;
   if p_call_result = 'Não atendeu' and p_whatsapp is null then raise exception 'Informe se chamou no WhatsApp.'; end if;
   if p_call_result = 'Não atendeu' and p_whatsapp = true and nullif(p_print_path,'') is null then raise exception 'Anexe o print da tentativa no WhatsApp.'; end if;
 end if;

 select full_name,email into actor from public.profiles where id=auth.uid();

 if lead.post_acceptance_call_made = true and p_call_made = false then raise exception 'Voce ja registrou que ligou para o cliente e nao pode alterar para Nao.'; end if;

 if lead.post_acceptance_call_made is distinct from p_call_made then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: ligacao',case when p_call_made then 'Ja ligou para o cliente: Sim.' else 'Ja ligou para o cliente: Nao.' end,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 
 if p_call_made and lead.post_acceptance_call_result is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: resultado', 'Resultado da ligacao: '||p_call_result,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
 
 if p_call_made and p_call_result = 'Falou com o cliente' and lead.post_acceptance_interaction is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: interacao',trim(p_interaction),auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;

 if p_call_made and p_call_result = 'Não atendeu' and p_whatsapp is not null and lead.post_acceptance_whatsapp_contacted is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: WhatsApp','Chamou no WhatsApp: '||case when p_whatsapp then 'Sim.' else 'Nao.' end,auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;

 if p_call_made and p_call_result = 'Não atendeu' and p_whatsapp = true and p_print_path is not null and lead.post_acceptance_whatsapp_print_path is null then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao: print','Print da tentativa no WhatsApp anexado.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;

 complete := p_call_made and (
   (p_call_result = 'Falou com o cliente' and nullif(trim(coalesce(p_interaction,'')),'') is not null) or
   (p_call_result = 'Não atendeu' and p_whatsapp = false) or
   (p_call_result = 'Não atendeu' and p_whatsapp = true and nullif(p_print_path,'') is not null)
 );

 update public.crm_leads set
   post_acceptance_call_made = coalesce(p_call_made, post_acceptance_call_made),
   post_acceptance_call_result = coalesce(p_call_result, post_acceptance_call_result),
   post_acceptance_interaction = coalesce(nullif(trim(p_interaction),''), post_acceptance_interaction),
   post_acceptance_whatsapp_contacted = coalesce(p_whatsapp, post_acceptance_whatsapp_contacted),
   post_acceptance_whatsapp_print_path = coalesce(nullif(p_print_path,''), post_acceptance_whatsapp_print_path),
   post_acceptance_qualification_completed_at = case when complete then now() else null end
 where id=p_lead_id;

 if complete then insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Qualificacao concluida','Qualificacao obrigatoria apos o aceite concluida.',auth.uid(),coalesce(nullif(actor.full_name,''),actor.email)); end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid 
    where n.nspname = 'public' and p.proname = 'process_expired_lead_assignments_queue' and p.pronargs = 0
  ) and exists (
    select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid 
    where n.nspname = 'public' and p.proname = 'process_expired_lead_assignments' and p.pronargs = 0
  ) then
    alter function public.process_expired_lead_assignments() rename to process_expired_lead_assignments_queue;
  end if;
end $$;
create or replace function public.process_expired_lead_assignments() returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare lead record; pending text;
begin
 for lead in select * from public.crm_leads where post_acceptance_qualification_deadline_at<=now() and post_acceptance_qualification_completed_at is null and post_acceptance_qualification_expired_at is null for update skip locked loop
   pending:=concat_ws('; ',case when lead.post_acceptance_call_made is null or lead.post_acceptance_call_made=false then 'resposta sobre ligacao' end, case when lead.post_acceptance_call_made=true and lead.post_acceptance_call_result is null then 'resultado da ligacao' end, case when lead.post_acceptance_call_made=true and lead.post_acceptance_call_result='Falou com o cliente' and nullif(trim(coalesce(lead.post_acceptance_interaction,'')),'') is null then 'interacao' end,case when lead.post_acceptance_call_made=true and lead.post_acceptance_call_result='Não atendeu' and lead.post_acceptance_whatsapp_contacted is null then 'resposta sobre WhatsApp' end,case when lead.post_acceptance_call_made=true and lead.post_acceptance_call_result='Não atendeu' and lead.post_acceptance_whatsapp_contacted=true and lead.post_acceptance_whatsapp_print_path is null then 'print do WhatsApp' end);
   update public.crm_leads set stage='Aguardando redistribuicao pelo Allyson',assignment_deadline_at=null,assignment_available_at=null,post_acceptance_qualification_expired_at=now() where id=lead.id;
   insert into public.crm_lead_activities(lead_id,stage,note,author_name) values(lead.id,'Qualificacao expirada','Prazo de 2 horas expirou. Pendencias: '||coalesce(pending,'nao identificadas')||'. Lead bloqueado e aguardando redistribuicao manual.','Sistema');
   insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload) select p.id,'lead_qualification_expired','Lead bloqueado: qualificacao expirada',lead.name||' / responsavel: '||coalesce(o.full_name,o.email)||'. Aceite: '||to_char(lead.post_acceptance_qualification_deadline_at-interval '2 hours','DD/MM/YYYY HH24:MI')||'. Pendencias: '||coalesce(pending,'nao identificadas')||'. Aguardando redistribuicao manual.','/leads',jsonb_build_object('leadId',lead.id,'pending',pending) from public.profiles p cross join public.profiles o where o.id=lead.owner_id and lower(trim(p.email)) in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid');
 end loop;
 perform public.process_expired_lead_assignments_queue();
end $$;

create or replace function public.guard_expired_lead_qualification() returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
 if old.post_acceptance_qualification_expired_at is not null and public.is_allyson_admin() and new.owner_id is distinct from old.owner_id then
   new.post_acceptance_qualification_deadline_at:=now()+interval '2 hours'; new.post_acceptance_call_made:=null; new.post_acceptance_call_result:=null; new.post_acceptance_interaction:=null; new.post_acceptance_whatsapp_contacted:=null; new.post_acceptance_whatsapp_print_path:=null; new.post_acceptance_qualification_completed_at:=null; new.post_acceptance_qualification_expired_at:=null; new.stage:='Em atendimento';
 elsif current_user not in ('postgres','service_role','supabase_admin') and old.post_acceptance_qualification_expired_at is not null and not public.is_allyson_admin() then raise exception 'Este lead esta retido para redistribuicao manual e nao pode mais ser alterado pelo corretor anterior.'; end if;
 return new;
end $$;
drop trigger if exists crm_leads_guard_expired_qualification on public.crm_leads;
create trigger crm_leads_guard_expired_qualification before update on public.crm_leads for each row execute function public.guard_expired_lead_qualification();

grant execute on function public.save_post_acceptance_lead_qualification(uuid,boolean,text,text,boolean,text) to authenticated;
revoke all on function public.process_expired_lead_assignments_queue() from public,anon,authenticated;
commit;
