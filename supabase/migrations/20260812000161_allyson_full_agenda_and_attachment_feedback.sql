begin;

-- Allyson can manage every agenda entry even after it has been completed.
create or replace function public.can_manage_agenda_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select auth.uid() is not null and (
    public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_agenda_entries entry
      where entry.id = p_entry_id
        and entry.feedback_at is null
        and (
          entry.source_kind is distinct from 'lead_visit'
          or public.is_admin()
          or entry.target_user_id = auth.uid()
          or exists (
            select 1
            from public.crm_agenda_entry_participants participant
            where participant.entry_id = entry.id
              and participant.user_id = auth.uid()
          )
        )
    )
  );
$$;

-- Keep the established agenda behavior and widen only Allyson's authorization.
do $$
declare
  definition text;
begin
  select pg_get_functiondef(
    'public.feedback_agenda_entry(uuid,timestamptz,text)'::regprocedure
  ) into definition;
  if position('if auth.uid() is distinct from agenda_entry.target_user_id and not exists (' in definition) = 0 then
    raise exception 'Formato inesperado de feedback_agenda_entry.';
  end if;
  definition := replace(
    definition,
    'if auth.uid() is distinct from agenda_entry.target_user_id and not exists (',
    'if not public.is_allyson_admin() and auth.uid() is distinct from agenda_entry.target_user_id and not exists ('
  );
  execute definition;

  select pg_get_functiondef(
    'public.save_agenda_cartorio_submission(uuid,date,date,jsonb)'::regprocedure
  ) into definition;
  if position('if derley is null or auth.uid() <> derley then' in definition) = 0 then
    raise exception 'Formato inesperado de save_agenda_cartorio_submission.';
  end if;
  definition := replace(
    definition,
    'if derley is null or auth.uid() <> derley then',
    'if not public.is_allyson_admin() and (derley is null or auth.uid() <> derley) then'
  );
  definition := replace(
    definition,
    'if entry.cartorio_protocol_revision_count >= 2 then',
    'if not public.is_allyson_admin() and entry.cartorio_protocol_revision_count >= 2 then'
  );
  execute definition;

  select pg_get_functiondef(
    'public.register_agenda_cartorio_milestone(uuid,text)'::regprocedure
  ) into definition;
  if position('if derley is null or auth.uid() <> derley then' in definition) = 0 then
    raise exception 'Formato inesperado de register_agenda_cartorio_milestone.';
  end if;
  definition := replace(
    definition,
    'if derley is null or auth.uid() <> derley then',
    'if not public.is_allyson_admin() and (derley is null or auth.uid() <> derley) then'
  );
  execute definition;

  select pg_get_functiondef(
    'public.save_agenda_cartorio_vitor_documents(uuid,jsonb)'::regprocedure
  ) into definition;
  if position('if vitor is null or auth.uid() is distinct from vitor then' in definition) = 0 then
    raise exception 'Formato inesperado de save_agenda_cartorio_vitor_documents.';
  end if;
  definition := replace(
    definition,
    'if vitor is null or auth.uid() is distinct from vitor then',
    'if not public.is_allyson_admin() and (vitor is null or auth.uid() is distinct from vitor) then'
  );
  execute definition;
end;
$$;

revoke all on function public.can_manage_agenda_entry(uuid) from public, anon;
grant execute on function public.can_manage_agenda_entry(uuid) to authenticated, service_role;
grant execute on function public.feedback_agenda_entry(uuid,timestamptz,text) to authenticated;
grant execute on function public.save_agenda_cartorio_submission(uuid,date,date,jsonb) to authenticated;
grant execute on function public.register_agenda_cartorio_milestone(uuid,text) to authenticated;
grant execute on function public.save_agenda_cartorio_vitor_documents(uuid,jsonb) to authenticated;

commit;
