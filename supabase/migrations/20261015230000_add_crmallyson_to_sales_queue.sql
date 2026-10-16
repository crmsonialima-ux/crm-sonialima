begin;

-- crmallyson mantém acesso administrativo, mas também participa da rotação
-- automática da fila de vendas como o quarto participante.
insert into public.lead_distribution_queue (lead_type, broker_id, position)
select 'Venda', profile.id, 4
from public.profiles as profile
where lower(trim(coalesce(profile.email, ''))) = 'crmsoniaallyson@gmail.com'
on conflict (lead_type, broker_id) do update
set position = excluded.position,
    updated_at = now();

-- A seleção da fila aceita o administrador crmallyson somente para vendas;
-- ele não perde o papel de administrador para entrar na rotação.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.get_next_property_lead_broker(text,text)'::regprocedure)
  into definition;

  if definition is null
    or position('lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''' in definition) = 0 then
    raise exception 'Definição inesperada de get_next_property_lead_broker';
  end if;

  definition := replace(
    definition,
    'lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''',
    'lower(trim(profile.email)) in (''unassigned-institutional@example.invalid'', ''crmsoniaallyson@gmail.com'')'
  );
  execute definition;

  select pg_get_functiondef('public.crm_restart_match_lead_queue(uuid)'::regprocedure)
  into definition;
  if definition is not null then
    definition := replace(
      definition,
      'lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''',
      'lower(trim(profile.email)) in (''unassigned-institutional@example.invalid'', ''crmsoniaallyson@gmail.com'')'
    );
    execute definition;
  end if;

end;
$$;

commit;
