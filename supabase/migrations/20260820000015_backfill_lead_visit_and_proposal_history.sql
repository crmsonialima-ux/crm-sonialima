-- Preserva nos indicadores os marcos que jÃ¡ constam no histÃ³rico do lead.
-- A etapa atual pode mudar livremente, mas visita realizada e proposta sÃ£o fatos permanentes.
begin;

with activity_milestones as (
  select
    activity.lead_id,
    min(activity.created_at) filter (where lower(trim(activity.stage)) = 'visita realizada') as first_visit_at,
    min(activity.created_at) filter (where lower(trim(activity.stage)) = 'proposta') as first_proposal_at
  from public.crm_lead_activities as activity
  group by activity.lead_id
)
update public.crm_leads as lead
set
  visit_completed_at = coalesce(lead.visit_completed_at, activity_milestones.first_visit_at),
  proposal_at = coalesce(lead.proposal_at, activity_milestones.first_proposal_at),
  updated_at = case
    when lead.visit_completed_at is null and activity_milestones.first_visit_at is not null then now()
    when lead.proposal_at is null and activity_milestones.first_proposal_at is not null then now()
    else lead.updated_at
  end
from activity_milestones
where lead.id = activity_milestones.lead_id
  and (
    (lead.visit_completed_at is null and activity_milestones.first_visit_at is not null)
    or (lead.proposal_at is null and activity_milestones.first_proposal_at is not null)
  );

commit;
