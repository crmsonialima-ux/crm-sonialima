begin;

-- A conta AcessoCRM representa o corretor institucional SoniaLima. Ela continua
-- administradora, mas participa exclusivamente da fila comercial de Venda.
delete from public.lead_distribution_queue as queue
using public.profiles as profile
where queue.broker_id = profile.id
  and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  and queue.lead_type <> 'Venda';

insert into public.lead_distribution_queue
  (lead_type, broker_id, broker_email, position)
select 'Venda', profile.id, 'SoniaLima',
  coalesce((select max(queue.position) + 1
            from public.lead_distribution_queue as queue
            where queue.lead_type = 'Venda'), 1)
from public.profiles as profile
where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
on conflict (lead_type, broker_id) do update
set broker_email = excluded.broker_email,
    updated_at = now();

-- Remove somente uma desativacao manual anterior. Penalidades temporarias e
-- bloqueios por pendencias continuam sendo respeitados.
update public.profiles
set lead_distribution_manually_disabled = false,
    lead_distribution_blocked = case
      when lead_distribution_blocked_reason = 'Desativado manualmente da fila pelo Allyson'
        then false else lead_distribution_blocked end,
    lead_distribution_blocked_at = case
      when lead_distribution_blocked_reason = 'Desativado manualmente da fila pelo Allyson'
        then null else lead_distribution_blocked_at end,
    lead_distribution_blocked_reason = case
      when lead_distribution_blocked_reason = 'Desativado manualmente da fila pelo Allyson'
        then null else lead_distribution_blocked_reason end,
    updated_at = now()
where lower(trim(email)) = 'unassigned-institutional@example.invalid';

-- Todos os imoveis atuais podem encaminhar seus leads de Venda ao SoniaLima.
insert into public.crm_property_broker_access (property_id, broker_id)
select property.external_id, profile.id
from public.crm_property_catalog as property
cross join public.profiles as profile
where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
on conflict (property_id, broker_id) do nothing;

-- Conserva o acesso global nos novos imoveis cadastrados.
create or replace function public.ensure_sonialima_property_lead_access()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.crm_property_broker_access (property_id, broker_id)
  select new.external_id, profile.id
  from public.profiles as profile
  where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  on conflict (property_id, broker_id) do nothing;
  return new;
end;
$$;

drop trigger if exists ensure_sonialima_property_lead_access
  on public.crm_property_catalog;
create trigger ensure_sonialima_property_lead_access
after insert on public.crm_property_catalog
for each row execute function public.ensure_sonialima_property_lead_access();

-- Reaplica a excecao institucional somente nas quatro rotinas oficiais da fila.
do $$
declare signature text; definition text; patched text;
begin
  foreach signature in array array[
    'public.create_distributed_lead(text,text,text,text,text,text,text,text,text,numeric,text)',
    'public.process_expired_lead_assignments()',
    'public.restart_exhausted_lead_queue(uuid)',
    'public.accept_lead_assignment(uuid)'
  ] loop
    select pg_get_functiondef(signature::regprocedure) into definition;
    patched := replace(
      definition,
      'profile.role = ''broker''',
      '(profile.role = ''broker'' or (queue.lead_type = ''Venda'' and lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''))'
    );
    -- Algumas rotinas atuais já não filtram por perfil neste ponto. Nelas não
    -- há nada a alterar; as demais recebem a exceção institucional acima.
    if patched is distinct from definition then
      execute patched;
    end if;
  end loop;
end;
$$;

-- O controle manual aceita SoniaLima apesar de o AcessoCRM permanecer admin.
do $$
declare definition text; patched text;
begin
  select pg_get_functiondef(
    'public.set_broker_lead_queue_enabled(uuid,boolean)'::regprocedure
  ) into definition;
  patched := replace(
    definition,
    'profile.id = p_broker_id and profile.role = ''broker''',
    'profile.id = p_broker_id and (profile.role = ''broker'' or lower(trim(profile.email)) = ''unassigned-institutional@example.invalid'')'
  );
  if patched = definition then
    raise exception 'Validacao esperada do controle da fila nao encontrada.';
  end if;
  execute patched;
end;
$$;

commit;
