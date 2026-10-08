begin;

-- O perfil acesso CRM continua sendo administrador, mas participa
-- comercialmente da Venda com o nome SoniaLima. A atribuicao direta precisa
-- aceitar a mesma excecao que a fila e a selecao de corretores ja utilizam.
do $$
declare
  definition text;
begin
  select pg_get_functiondef(
    'public.create_admin_assigned_lead(text,text,text,text,text,text,text,text,numeric,text,uuid)'::regprocedure
  ) into definition;

  if position('and role = ''broker''' in definition) = 0 then
    raise exception 'Validacao de corretor esperada nao encontrada em create_admin_assigned_lead.';
  end if;

  definition := replace(
    definition,
    'and role = ''broker''',
    'and (role = ''broker'' or (p_lead_type = ''Venda'' and lower(trim(email)) = ''unassigned-institutional@example.invalid''))'
  );
  execute definition;

  select pg_get_functiondef(
    'public.transfer_lead_directly(uuid,uuid)'::regprocedure
  ) into definition;

  if position('and profile.role = ''broker''' in definition) = 0 then
    raise exception 'Validacao de corretor esperada nao encontrada em transfer_lead_directly.';
  end if;

  definition := replace(
    definition,
    'and profile.role = ''broker''',
    'and (profile.role = ''broker'' or (lead_record.lead_type = ''Venda'' and lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''))'
  );
  execute definition;
end;
$$;

commit;
