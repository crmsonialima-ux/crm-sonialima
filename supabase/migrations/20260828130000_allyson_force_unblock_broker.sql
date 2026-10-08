begin;

create or replace function public.force_unblock_broker_lead_queue(p_broker_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor public.profiles%rowtype;
begin
  select * into actor
  from public.profiles
  where id = auth.uid();

  if actor.id is null
     or actor.role is distinct from 'admin'
     or (
       actor.id <> '37094db7-2457-48f2-8573-40c887e547e5'::uuid
       and lower(trim(coalesce(actor.email, ''))) <> 'crmsoniaallyson@gmail.com'
     ) then
    raise exception 'Somente Allyson pode desbloquear corretores da fila.';
  end if;

  if not exists (
    select 1
    from public.lead_distribution_queue as queue
    where queue.broker_id = p_broker_id
  ) then
    raise exception 'Corretor nao encontrado na fila de leads.';
  end if;

  update public.profiles
  set lead_distribution_blocked = false,
      lead_distribution_manually_disabled = false,
      lead_distribution_blocked_at = null,
      lead_distribution_blocked_until = null,
      lead_distribution_blocked_reason = null,
      updated_at = now()
  where id = p_broker_id;

  if not found then
    raise exception 'Perfil do corretor nao encontrado.';
  end if;
end;
$$;

revoke all on function public.force_unblock_broker_lead_queue(uuid)
  from public, anon;
grant execute on function public.force_unblock_broker_lead_queue(uuid)
  to authenticated;

commit;
