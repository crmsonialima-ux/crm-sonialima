begin;

create or replace function public.guard_expired_lead_qualification() returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
 -- Reset qualification status if Allyson redistributes an expired lead
 if old.post_acceptance_qualification_expired_at is not null and public.is_allyson_admin() and new.owner_id is distinct from old.owner_id then
   new.post_acceptance_qualification_deadline_at:=now()+interval '2 hours'; 
   new.post_acceptance_call_made:=null; 
   new.post_acceptance_call_result:=null; 
   new.post_acceptance_interaction:=null; 
   new.post_acceptance_whatsapp_contacted:=null; 
   new.post_acceptance_whatsapp_print_path:=null; 
   new.post_acceptance_qualification_completed_at:=null; 
   new.post_acceptance_qualification_expired_at:=null; 
   new.stage:='Em atendimento';
 
 -- Block modifications from previous broker if lead is expired
 elsif current_user not in ('postgres','service_role','supabase_admin') and old.post_acceptance_qualification_expired_at is not null and not public.is_allyson_admin() then 
   raise exception 'Este lead esta retido para redistribuicao manual e nao pode mais ser alterado pelo corretor anterior.'; 
 
 -- NEW RULE: Block stage change (escaping the flow) if qualification is pending
 elsif current_user not in ('postgres','service_role','supabase_admin') 
   and old.post_acceptance_qualification_deadline_at is not null
   and old.post_acceptance_qualification_completed_at is null
   and old.post_acceptance_qualification_expired_at is null
   and new.stage is distinct from old.stage 
   and new.stage <> 'Em atendimento'
 then
   raise exception 'Complete a qualificação pós-aceite antes de avançar o estágio do lead.';
 end if;

 return new;
end $$;

commit;
