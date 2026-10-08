begin;

-- A tabela de captadores usa broker_name e set_by. A RPC da fase 1 ainda
-- referenciava a coluna legada assigned_by, o que impedia salvar qualquer
-- corretor. SoniaLima e o perfil institucional acessocrm tambem sao captadores
-- validos, embora este ultimo seja administrador no cadastro de perfis.
do $$
declare
  definition text;
begin
  select pg_get_functiondef(
    'public.submit_property_authorization_phase1(text,jsonb,jsonb,uuid)'::regprocedure
  ) into definition;

  if definition is null or position('assigned_by' in definition) = 0 then
    raise exception 'A definicao esperada da RPC de captacao nao foi encontrada.';
  end if;

  definition := replace(
    definition,
    'WHERE id = p_capturer_id AND role = ''broker''',
    'WHERE id = p_capturer_id AND (role = ''broker'' OR (role = ''admin'' AND lower(trim(email)) = ''unassigned-institutional@example.invalid''))'
  );

  definition := regexp_replace(
    definition,
    'INSERT INTO public[.]crm_property_capturer_assignments[[:space:]]*[(][[:space:]]*property_id,[[:space:]]*broker_id,[[:space:]]*assigned_by[[:space:]]*[)][[:space:]]*VALUES[[:space:]]*[(][[:space:]]*p_external_id,[[:space:]]*p_capturer_id,[[:space:]]*auth[.]uid[(][)][[:space:]]*[)]',
    'INSERT INTO public.crm_property_capturer_assignments (property_id, broker_id, broker_name, set_by) VALUES (p_external_id, p_capturer_id, (select case when lower(trim(email)) = ''unassigned-institutional@example.invalid'' then ''SoniaLima'' else coalesce(nullif(trim(full_name), ''''), email) end from public.profiles where id = p_capturer_id), auth.uid())'
  );

  if position('assigned_by' in definition) > 0 then
    raise exception 'Nao foi possivel atualizar a gravacao do captador na RPC.';
  end if;

  execute definition;
end;
$$;

revoke all on function public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid)
  from public, anon;
grant execute on function public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid)
  to authenticated, service_role;

commit;
