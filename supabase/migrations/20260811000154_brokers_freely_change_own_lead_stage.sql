begin;

alter table public.crm_leads
  add column if not exists commercial_qualification_required boolean not null default false;

-- Todos os registros que ja existiam permanecem dispensados. Somente INSERTs
-- realizados depois desta migration recebem a nova obrigatoriedade.
alter table public.crm_leads
  alter column commercial_qualification_required set default true;

create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
  is_direct_user_change boolean := auth.uid() is not null and pg_trigger_depth() = 1;
begin
  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'em atendimento'
     and new_stage <> 'em atendimento' then
    if new.has_property_to_sell is null
       or new.needs_financing is null
       or new.will_use_fgts is null
       or new.banking_correspondent_presented is null then
      raise exception 'Responda todas as perguntas da qualificacao comercial antes de alterar a etapa.';
    end if;

    if new.has_property_to_sell
       and (
         nullif(trim(new.property_to_sell_location), '') is null
         or new.property_to_sell_value is null
         or new.property_to_sell_value <= 0
       ) then
      raise exception 'Informe a localizacao e o valor do imovel que o lead pretende vender.';
    end if;
  end if;

  -- A resposta da captacao pertence exclusivamente ao registro da etapa
  -- Visita realizada. As demais trocas de etapa sao livres.
  if is_direct_user_change
     and new_stage = 'visita realizada'
     and old_stage <> 'visita realizada'
     and new.visit_property_captured is null then
    raise exception 'Informe se o imovel do cliente foi captado durante a visita.';
  end if;
  return new;
end;
$$;

create or replace function public.protect_lead_data_from_unauthorized_edits()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in ('postgres', 'service_role', 'supabase_admin');
  full_editor boolean;
  old_protected jsonb;
  new_protected jsonb;
begin
  if trusted_backend then return new; end if;
  full_editor := public.is_allyson_admin() or public.is_restricted_admin();
  if full_editor then return new; end if;

  old_protected := to_jsonb(old)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'has_property_to_sell' - 'property_to_sell_location'
    - 'property_to_sell_value' - 'needs_financing' - 'will_use_fgts'
    - 'banking_correspondent_presented' - 'visit_property_captured';
  new_protected := to_jsonb(new)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'has_property_to_sell' - 'property_to_sell_location'
    - 'property_to_sell_value' - 'needs_financing' - 'will_use_fgts'
    - 'banking_correspondent_presented' - 'visit_property_captured';

  if new_protected is distinct from old_protected then
    raise exception 'Corretores podem alterar a etapa e registrar o atendimento. Solicite ao Allyson ou ao acesso CRM qualquer alteracao cadastral.';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_lead_commercial_qualification()
  from public, anon, authenticated;
revoke all on function public.protect_lead_data_from_unauthorized_edits()
  from public, anon, authenticated;

commit;
