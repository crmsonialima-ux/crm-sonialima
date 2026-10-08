begin;

alter table public.crm_financing_processes
  add column if not exists credit_bank text;

create or replace function public.update_financing_credit_decision(
  p_process_id uuid,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version bigint default null,
  p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  approved boolean;
  bank_name text;
  next_bank text;
  previous_bank text;
  next_version bigint;
begin
  approved := (p_payload->>'approved')::boolean;
  bank_name := nullif(btrim(p_payload->>'bank'), '');
  next_bank := case when approved then bank_name else null end;

  if approved and bank_name is null then
    raise exception 'Informe qual foi o banco que aprovou o crédito.';
  end if;

  select credit_bank
  into previous_bank
  from public.crm_financing_processes
  where id = p_process_id;

  next_version := public.update_financing_process(
    p_process_id,
    'credit_decision',
    p_payload,
    p_expected_version,
    p_note
  );

  update public.crm_financing_processes
  set credit_bank = next_bank
  where id = p_process_id;

  if previous_bank is distinct from next_bank then
    perform public.crm_financing_add_history(
      p_process_id,
      'credit',
      'credit_bank',
      'credit_bank',
      to_jsonb(previous_bank),
      to_jsonb(next_bank),
      p_note,
      null
    );
  end if;

  return next_version;
end;
$$;

revoke all on function public.update_financing_credit_decision(uuid, jsonb, bigint, text)
  from public, anon;
grant execute on function public.update_financing_credit_decision(uuid, jsonb, bigint, text)
  to authenticated;

commit;
