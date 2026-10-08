begin;

-- O painel le a tabela da fila diretamente, mas a selecao efetiva de destino
-- tambem validava role=broker. AcessoCRM permanece admin; torna-lo elegivel
-- somente em Venda mantem a permissao administrativa sem abrir Aluguel.
do $$
declare definition text; patched text;
begin
  select pg_get_functiondef(
    'public.get_next_property_lead_broker(text,text)'::regprocedure
  ) into definition;

  patched := replace(
    definition,
    'and profile.role = ''broker''',
    'and (profile.role = ''broker'' or (p_lead_type = ''Venda'' and lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''))'
  );

  if patched = definition then
    raise exception 'Filtro de perfil esperado nao encontrado na distribuicao.';
  end if;

  execute patched;
end;
$$;

commit;
