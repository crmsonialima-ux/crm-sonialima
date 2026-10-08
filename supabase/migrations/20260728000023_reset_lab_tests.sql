-- Reinicia somente dados de teste do Laboratório, preservando toda operação real.
create or replace function public.reset_assignment_notification_tests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare removed_count integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem reiniciar os testes.';
  end if;

  update public.crm_assignment_test_runs
  set status = 'cancelled', completed_at = now()
  where status = 'running';

  delete from public.crm_notification_outbox
  where kind in (
    'assignment_lab',
    'assignment_lab_complete',
    'assignment_queue_separation_test'
  );

  get diagnostics removed_count = row_count;
  return removed_count;
end;
$$;

grant execute on function public.reset_assignment_notification_tests() to authenticated;
