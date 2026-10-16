begin;

-- A conta operacional tem um único nome em todas as telas e relatórios.
update public.profiles
set full_name = 'crmallyson'
where lower(trim(coalesce(email, ''))) = 'crmsoniaallyson@gmail.com';

-- Estes são os três corretores que recebem a distribuição automática. A conta
-- crmallyson faz a distribuição e pode atribuir um lead a si mesma, mas não é
-- um destinatário automático da fila.
update public.profiles
set role = 'broker',
    lead_distribution_manually_disabled = false,
    lead_distribution_blocked = false,
    lead_distribution_blocked_reason = null,
    lead_distribution_blocked_at = null,
    lead_distribution_blocked_until = null
where lower(trim(coalesce(email, ''))) in (
  'crmdanilo@gmail.com',
  'crmnoemia@gmail.com',
  'crmsonia@gmail.com'
);

-- Reconstrói a fila única de vendas na ordem visível no painel. Nenhuma fila
-- de aluguel continua cadastrada.
delete from public.lead_distribution_queue;

insert into public.lead_distribution_queue (lead_type, broker_id, position)
select
  'Venda',
  profile.id,
  case lower(trim(profile.email))
    when 'crmdanilo@gmail.com' then 1
    when 'crmnoemia@gmail.com' then 2
    when 'crmsonia@gmail.com' then 3
  end
from public.profiles as profile
where lower(trim(coalesce(profile.email, ''))) in (
  'crmdanilo@gmail.com',
  'crmnoemia@gmail.com',
  'crmsonia@gmail.com'
);

-- A função de ranking tinha o nome antigo fixado, independentemente do perfil.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.get_capture_ranking_rows()'::regprocedure)
  into definition;

  if definition is null or position('then ''Allyson''' in definition) = 0 then
    raise exception 'Definição inesperada de get_capture_ranking_rows';
  end if;

  definition := replace(definition, 'then ''Allyson''', 'then ''crmallyson''');
  execute definition;
end;
$$;

commit;
