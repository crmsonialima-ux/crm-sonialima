begin;

create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
begin
  -- A exigencia se aplica às alterações feitas por usuários. Processamentos
  -- automáticos da esteira e dos prazos continuam autorizados a operar.
  if auth.uid() is not null
     and old_stage = 'em atendimento'
     and new_stage <> 'em atendimento' then
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

  if auth.uid() is not null and (
    (new_stage = 'visita realizada' and old_stage <> 'visita realizada')
    or (old_stage = 'visita realizada' and new_stage <> 'visita realizada')
  ) and new.visit_property_captured is null then
    raise exception 'Informe se o imóvel do cliente foi captado durante a visita.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_lead_commercial_qualification()
  from public, anon, authenticated;

commit;
