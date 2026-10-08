begin;

-- A broker explicitly selected by Allyson is a direct assignment. It must not
-- consume or continue the automatic queue started by the generic insert trigger.
create or replace function public.create_allyson_assigned_lead_with_phones(
  p_name text,
  p_phone text,
  p_additional_phones text[],
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_owner_id uuid,
  p_visit_scheduled_at timestamptz default null
)
returns table (
  lead_id uuid,
  assigned_owner_id uuid,
  assigned_owner_name text
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  created_lead record;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode atribuir um novo lead diretamente a um corretor.';
  end if;
  if p_owner_id is null then
    raise exception 'Selecione o corretor responsavel.';
  end if;

  if p_visit_scheduled_at is not null then
    select *
    into created_lead
    from public.create_scheduled_visit_lead(
      p_name,
      p_phone,
      p_email,
      p_property_interest,
      p_channel,
      p_notes,
      p_lead_type,
      p_desired_property_value,
      p_desired_location,
      p_owner_id,
      p_visit_scheduled_at
    );
  else
    select *
    into created_lead
    from public.create_admin_assigned_lead(
      p_name,
      p_phone,
      p_email,
      p_property_interest,
      p_stage,
      p_channel,
      p_notes,
      p_lead_type,
      p_desired_property_value,
      p_desired_location,
      p_owner_id
    );

    update public.crm_leads as lead
    set stage = p_stage,
        assignment_status = 'accepted',
        assignment_available_at = null,
        assignment_deadline_at = null,
        assignment_reminder_sent_at = null,
        updated_at = now()
    where lead.id = created_lead.lead_id;

    delete from public.lead_assignment_attempts as attempt
    where attempt.lead_id = created_lead.lead_id;

    delete from public.crm_notification_outbox as notification
    where notification.kind = 'lead_assignment'
      and notification.payload ->> 'leadId' = created_lead.lead_id::text;

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload
    ) values (
      created_lead.assigned_owner_id,
      'lead_direct_assignment',
      'Novo lead atribuido por Allyson',
      trim(p_name) || ' foi atribuido diretamente a voce e nao passara pela fila automatica.',
      '/leads',
      jsonb_build_object(
        'leadId', created_lead.lead_id,
        'name', trim(p_name),
        'phone', nullif(trim(p_phone), ''),
        'assignedDirectly', true
      )
    );

    insert into public.crm_lead_activities (
      lead_id,
      stage,
      note,
      author_id,
      author_name
    ) values (
      created_lead.lead_id,
      'Lead atribuido diretamente',
      'Allyson definiu o corretor responsavel sem iniciar a fila automatica.',
      auth.uid(),
      'crmallyson'
    );
  end if;

  if created_lead.lead_id is null then
    raise exception 'Nao foi possivel cadastrar o lead para o corretor selecionado.';
  end if;

  update public.crm_leads as lead
  set additional_phones = coalesce(p_additional_phones, '{}'::text[]),
      assignment_available_at = null
  where lead.id = created_lead.lead_id;

  return query
  select
    created_lead.lead_id,
    created_lead.assigned_owner_id,
    created_lead.assigned_owner_name;
end;
$$;

insert into public.crm_notification_delivery_policies (
  kind,
  delivery_mode,
  rationale
)
values (
  'lead_direct_assignment',
  'business_hours',
  'Atribuicao direta informativa, sem prazo de aceite e sem participacao na esteira.'
)
on conflict (kind) do update
set delivery_mode = excluded.delivery_mode,
    rationale = excluded.rationale,
    updated_at = now();

revoke all on function public.create_allyson_assigned_lead_with_phones(
  text,
  text,
  text[],
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  text,
  uuid,
  timestamptz
) from public, anon, authenticated;
grant execute on function public.create_allyson_assigned_lead_with_phones(
  text,
  text,
  text[],
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  text,
  uuid,
  timestamptz
) to authenticated;

comment on function public.create_allyson_assigned_lead_with_phones(
  text,
  text,
  text[],
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  text,
  uuid,
  timestamptz
) is 'Cria um lead diretamente para o corretor escolhido por Allyson, sem girar a fila automatica.';

commit;
