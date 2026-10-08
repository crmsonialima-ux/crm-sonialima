begin;

alter table public.crm_leads
  add column if not exists has_property_to_sell boolean,
  add column if not exists property_to_sell_location text,
  add column if not exists property_to_sell_value numeric,
  add column if not exists needs_financing boolean,
  add column if not exists will_use_fgts boolean,
  add column if not exists banking_correspondent_presented boolean,
  add column if not exists visit_property_captured boolean;

alter table public.crm_leads
  drop constraint if exists crm_leads_property_to_sell_details_check;
alter table public.crm_leads
  add constraint crm_leads_property_to_sell_details_check check (
    has_property_to_sell is distinct from true
    or (
      nullif(trim(property_to_sell_location), '') is not null
      and property_to_sell_value > 0
    )
  );

create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
begin
  if old_stage = 'em atendimento' and new_stage <> 'em atendimento' then
    if new.has_property_to_sell is null
       or new.needs_financing is null
       or new.will_use_fgts is null
       or new.banking_correspondent_presented is null then
      raise exception 'Responda todas as perguntas da qualificação comercial antes de alterar a etapa.';
    end if;

    if new.has_property_to_sell
       and (
         nullif(trim(new.property_to_sell_location), '') is null
         or new.property_to_sell_value is null
         or new.property_to_sell_value <= 0
       ) then
      raise exception 'Informe a localização e o valor do imóvel que o lead pretende vender.';
    end if;
  end if;

  if (
    new_stage = 'visita realizada'
    and old_stage <> 'visita realizada'
  ) or (
    old_stage = 'visita realizada'
    and new_stage <> 'visita realizada'
  ) then
    if new.visit_property_captured is null then
      raise exception 'Informe se o imóvel do cliente foi captado durante a visita.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists zzz_crm_leads_require_commercial_qualification
  on public.crm_leads;
create trigger zzz_crm_leads_require_commercial_qualification
before update of stage, has_property_to_sell, property_to_sell_location,
  property_to_sell_value, needs_financing, will_use_fgts,
  banking_correspondent_presented, visit_property_captured
on public.crm_leads
for each row execute function public.enforce_lead_commercial_qualification();

revoke all on function public.enforce_lead_commercial_qualification()
  from public, anon, authenticated;

commit;
