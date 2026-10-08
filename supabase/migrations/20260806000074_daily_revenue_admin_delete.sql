-- Administradores, incluindo a conta exclusiva de validacao, podem excluir
-- lancamentos do preenchimento diario. A acao permanece protegida por RLS e
-- entra na trilha imutavel de auditoria.

grant delete on table public.crm_daily_broker_revenue to authenticated;

drop policy if exists "Admins delete daily broker revenue"
  on public.crm_daily_broker_revenue;
create policy "Admins delete daily broker revenue"
  on public.crm_daily_broker_revenue
  for delete
  to authenticated
  using (public.is_admin());

create or replace function public.audit_daily_broker_revenue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  revenue_row public.crm_daily_broker_revenue;
begin
  if tg_op = 'DELETE' then
    revenue_row := old;
  else
    revenue_row := new;
  end if;

  perform public.append_crm_audit_event(
    revenue_row.broker_id,
    auth.uid(),
    'daily_revenue',
    case
      when tg_op = 'DELETE' then 'daily_revenue_deleted'
      else 'daily_revenue_created'
    end,
    case when tg_op = 'DELETE' then 'deleted' else 'created' end,
    'daily_revenue',
    revenue_row.id,
    null,
    case when tg_op = 'DELETE' then now() else revenue_row.created_at end,
    case
      when tg_op = 'DELETE' then 'Lancamento diario excluido'
      else 'Lancamento diario criado'
    end,
    jsonb_build_object(
      'occurredOn', revenue_row.occurred_on,
      'kind', revenue_row.kind,
      'amount', revenue_row.amount,
      'brokerName', revenue_row.broker_name,
      'createdBy', revenue_row.created_by
    ),
    null,
    case
      when tg_op = 'INSERT' then 'daily-revenue:' || revenue_row.id || ':created'
      else 'daily-revenue:' || revenue_row.id || ':deleted'
    end
  );

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.audit_daily_broker_revenue()
  from public, anon, authenticated;

drop trigger if exists crm_daily_broker_revenue_audit
  on public.crm_daily_broker_revenue;
create trigger crm_daily_broker_revenue_audit
after insert or delete on public.crm_daily_broker_revenue
for each row execute function public.audit_daily_broker_revenue();
