-- A operação passa a usar somente uma fila de vendas. Aluguel não participa mais da fila.
delete from public.lead_distribution_queue where lead_type = 'Aluguel';

-- Todos os corretores já cadastrados ficam visíveis no painel do Allyson e
-- podem ser ativados/desativados individualmente.
insert into public.lead_distribution_queue (lead_type, broker_id, position)
select
  'Venda',
  profile.id,
  (
    (select coalesce(max(existing_queue.position), 0)
     from public.lead_distribution_queue as existing_queue
     where existing_queue.lead_type = 'Venda')
    + row_number() over (order by profile.created_at, profile.id)
  )::integer
from public.profiles as profile
where profile.role = 'broker'
on conflict (lead_type, broker_id) do nothing;

update public.profiles
set lead_distribution_manually_disabled = false,
    lead_distribution_blocked = false,
    lead_distribution_blocked_reason = null,
    lead_distribution_blocked_at = null,
    lead_distribution_blocked_until = null
where role = 'broker';
