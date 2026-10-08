-- Caixa de entrada persistente para notificações de cada usuário.
alter table public.crm_notification_outbox
  add column if not exists read_at timestamptz,
  add column if not exists dismissed_at timestamptz;

create index if not exists crm_notification_outbox_inbox_idx
  on public.crm_notification_outbox (recipient_id, created_at desc)
  where dismissed_at is null;

grant update (read_at, dismissed_at) on public.crm_notification_outbox to authenticated;

drop policy if exists "Users update their notifications" on public.crm_notification_outbox;
create policy "Users update their notifications"
  on public.crm_notification_outbox
  for update
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());
