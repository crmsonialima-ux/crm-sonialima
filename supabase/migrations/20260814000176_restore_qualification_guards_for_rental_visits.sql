begin;

-- A migration 174 precisou redefinir esta funcao para permitir a criacao
-- atomica de visitas de aluguel. Reaplicamos aqui todas as regras vigentes da
-- migration 155, incluindo a dispensa dos leads legados, e mantemos a excecao
-- estritamente ligada ao ID do lead que acabou de ser criado pela RPC.
create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
  is_initial_visit_creation boolean := coalesce(
    current_setting('crm.initial_visit_lead_id', true),
    ''
  ) = new.id::text;
  is_direct_user_change boolean := auth.uid() is not null
    and pg_trigger_depth() = 1
    and not is_initial_visit_creation;
begin
  -- Somente leads novos carregam commercial_qualification_required=true.
  -- A criacao atomica de visita e uma transicao interna do cadastro e nao
  -- representa a conclusao da qualificacao comercial.
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

  -- A resposta da captacao continua sendo exigida somente ao sair de Visita
  -- realizada e apenas para leads criados apos a regra de qualificacao.
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

comment on function public.enforce_lead_commercial_qualification() is
  'Exige qualificacao uma unica vez para leads novos; preserva leads legados e permite somente a transicao interna da criacao atomica de visita.';

commit;
