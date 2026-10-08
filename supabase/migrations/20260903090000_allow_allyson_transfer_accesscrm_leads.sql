begin;

create or replace function public.enforce_accesscrm_premium_lead_rules()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  new_owner_is_accesscrm boolean := public.is_accesscrm_profile(new.owner_id);
  old_owner_is_accesscrm boolean := false;
  direct_transfer_lead_id text := nullif(
    current_setting('crm.allyson_direct_transfer_lead_id', true),
    ''
  );
  direct_transfer_owner_id text := nullif(
    current_setting('crm.allyson_direct_transfer_owner_id', true),
    ''
  );
  is_allyson_direct_transfer boolean := false;
begin
  if tg_op = 'UPDATE' then
    old_owner_is_accesscrm := public.is_accesscrm_profile(old.owner_id);
    is_allyson_direct_transfer := direct_transfer_lead_id = old.id::text
      and public.is_allyson_admin();

    -- A posse premium impede redistribuições e penalidades automáticas. A
    -- transferência administrativa explícita do Allyson continua permitida.
    if old_owner_is_accesscrm
       and old.accesscrm_permanent_owner
       and new.owner_id is distinct from old.owner_id
       and not is_allyson_direct_transfer then
      raise exception 'Lead aceito pelo SoniaLima pertence permanentemente ao AcessoCRM.';
    end if;

    if old_owner_is_accesscrm
       and old.accesscrm_permanent_owner
       and not is_allyson_direct_transfer then
      new.assignment_status := 'accepted';
      new.accesscrm_permanent_owner := true;
    end if;
  end if;

  if not new_owner_is_accesscrm then
    new.accesscrm_permanent_owner := false;
    return new;
  end if;

  if direct_transfer_owner_id = new.owner_id::text then
    new.accesscrm_permanent_owner := true;
  end if;

  new.commercial_qualification_required := false;
  new.post_acceptance_qualification_deadline_at := null;
  new.post_acceptance_qualification_completed_at := null;
  new.post_acceptance_qualification_expired_at := null;
  new.post_acceptance_call_made := null;
  new.post_acceptance_call_result := null;
  new.post_acceptance_interaction := null;
  new.post_acceptance_whatsapp_contacted := null;
  new.post_acceptance_whatsapp_print_path := null;
  new.post_acceptance_whatsapp_has_whatsapp := null;

  if new.assignment_status = 'accepted' and new.accesscrm_permanent_owner then
    new.assignment_available_at := null;
    new.assignment_deadline_at := null;
    new.assignment_reminder_sent_at := null;

    if tg_op = 'INSERT'
       or old.accesscrm_permanent_owner is distinct from true
       or new.owner_id is distinct from old.owner_id then
      new.stage := '';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_accesscrm_premium_lead_rules() from public, anon, authenticated;

commit;
