begin;

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
  -- Somente leads novos carregam commercial_qualification_required=true.
  -- As respostas persistem no lead; ao retornar a Em atendimento, nao sao
  -- solicitadas novamente se ja estiverem completas.
  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'em atendimento'
     and new_stage <> 'em atendimento' then
    if new.has_property_to_sell is null
       or new.needs_financing is null
       or new.will_use_fgts is null
       or new.banking_correspondent_presented is null then
      raise exception 'Responda todas as perguntas da qualificacao comercial antes de sair de Em atendimento.';
    end if;
    if new.has_property_to_sell and (
      nullif(trim(new.property_to_sell_location), '') is null
      or new.property_to_sell_value is null
      or new.property_to_sell_value <= 0
    ) then
      raise exception 'Informe a localizacao e o valor do imovel que o lead pretende vender.';
    end if;
  end if;

  -- O lead pode entrar em Visita realizada. Para sair, os leads novos devem
  -- ter a resposta registrada. Uma resposta anterior continua valendo.
  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'visita realizada'
     and new_stage <> 'visita realizada'
     and new.visit_property_captured is null then
    raise exception 'Informe se o imovel do cliente foi captado antes de sair de Visita realizada.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_lead_commercial_qualification()
  from public, anon, authenticated;

comment on column public.crm_leads.commercial_qualification_required is
  'True apenas para leads criados apos a regra; respostas comerciais e de captacao sao exigidas uma unica vez.';

commit;
