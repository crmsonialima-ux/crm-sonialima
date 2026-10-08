grant delete on public.crm_daily_broker_revenue to authenticated;

create policy "Admins delete daily broker revenue"
on public.crm_daily_broker_revenue
for delete
using (public.is_admin());
