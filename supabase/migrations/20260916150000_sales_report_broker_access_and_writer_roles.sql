begin;

-- AcessoCRM consulta as vendas e os valores, mas somente Vitor e Allyson
-- podem criar ou alterar um relatório. Mantemos a validação dentro da RPC,
-- inclusive quando chamada diretamente fora da interface.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.save_crm_sale(uuid,jsonb)'::regprocedure)
    into definition;
  if position(
    'actor_email not in (''unassigned-operator@example.invalid'', ''crmsoniaallyson@gmail.com'', ''unassigned-institutional@example.invalid'')'
    in definition
  ) = 0 then
    raise exception 'Unexpected sales writer authorization definition';
  end if;
  definition := replace(
    definition,
    'actor_email not in (''unassigned-operator@example.invalid'', ''crmsoniaallyson@gmail.com'', ''unassigned-institutional@example.invalid'')',
    'actor_email not in (''unassigned-operator@example.invalid'', ''crmsoniaallyson@gmail.com'')'
  );
  execute definition;
end $$;

commit;
