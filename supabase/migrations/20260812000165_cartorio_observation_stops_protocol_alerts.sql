begin;

alter table public.crm_agenda_entries
  add column if not exists cartorio_protocol_observation text,
  add column if not exists cartorio_protocol_observation_at timestamptz,
  add column if not exists cartorio_protocol_observation_by uuid references public.profiles(id);

create or replace function public.save_agenda_cartorio_observation(
  p_id uuid,
  p_observation text
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  entry public.crm_agenda_entries%rowtype;
begin
  if nullif(trim(p_observation), '') is null then
    raise exception 'A observação do cartório é obrigatória.';
  end if;

  select agenda.* into entry
  from public.crm_agenda_entries as agenda
  where agenda.id = p_id
  for update;
  if not found or entry.category::text <> 'cartorio' then
    raise exception 'Demanda de cartório não encontrada.';
  end if;
  if not public.is_allyson_admin() and entry.target_user_id <> auth.uid() then
    raise exception 'Somente o responsável pela demanda ou Allyson pode salvar esta observação.';
  end if;

  update public.crm_agenda_entries as agenda
  set cartorio_protocol_observation = trim(p_observation),
      cartorio_protocol_observation_at = now(),
      cartorio_protocol_observation_by = auth.uid(),
      protocol_reminder_sent_at = now(),
      updated_at = now()
  where agenda.id = entry.id
  returning agenda.* into entry;

  -- Os avisos já visíveis também saem do sininho. A auditoria da Validação
  -- continua preservando criação, entrega, leitura e remoção.
  update public.crm_notification_outbox as notification
  set dismissed_at = coalesce(notification.dismissed_at, now()),
      read_at = coalesce(notification.read_at, now())
  where notification.payload ->> 'agendaId' = entry.id::text
    and (
      notification.kind = 'agenda_protocol_reminder'
      or (
        notification.kind = 'agenda_escalation'
        and lower(notification.title) like '%protocolo%'
      )
    );

  return entry;
end;
$$;

revoke all on function public.save_agenda_cartorio_observation(uuid,text)
from public, anon;
grant execute on function public.save_agenda_cartorio_observation(uuid,text)
to authenticated;

-- Defesa central: mesmo que a rotina agendada tente recriar um lembrete, ele
-- não entra no outbox depois de a observação obrigatória ter sido registrada.
create or replace function public.suppress_observed_cartorio_protocol_alert()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  agenda_id uuid;
begin
  if new.kind <> 'agenda_protocol_reminder'
     and not (
       new.kind = 'agenda_escalation'
       and lower(coalesce(new.title, '')) like '%protocolo%'
     ) then
    return new;
  end if;

  begin
    agenda_id := nullif(new.payload ->> 'agendaId', '')::uuid;
  exception when invalid_text_representation then
    return new;
  end;
  if agenda_id is null then return new; end if;

  if exists (
    select 1
    from public.crm_agenda_entries as agenda
    where agenda.id = agenda_id
      and nullif(trim(agenda.cartorio_protocol_observation), '') is not null
  ) then
    return null;
  end if;
  return new;
end;
$$;

revoke all on function public.suppress_observed_cartorio_protocol_alert()
from public, anon, authenticated;

drop trigger if exists suppress_observed_cartorio_protocol_alert
on public.crm_notification_outbox;
create trigger suppress_observed_cartorio_protocol_alert
before insert on public.crm_notification_outbox
for each row execute function public.suppress_observed_cartorio_protocol_alert();

commit;
