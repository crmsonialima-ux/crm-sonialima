begin;

alter table public.crm_property_value_reviews
  add column if not exists review_text text,
  add column if not exists sonialima_note text;

create or replace function public.respond_property_value_review_details(
  p_request_id uuid,
  p_decision text,
  p_new_value numeric,
  p_change_note text,
  p_review_text text,
  p_sonialima_note text
)
returns public.crm_property_value_reviews
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  request_row public.crm_property_value_reviews;
  formatted_current text;
  formatted_new text;
begin
  if not public.is_restricted_admin() then
    raise exception 'Somente o SoniaLima pode responder à revisão do imóvel.';
  end if;
  if nullif(trim(coalesce(p_review_text, '')), '') is null then
    raise exception 'Informe o texto revisado do imóvel.';
  end if;

  select review.* into request_row
  from public.crm_property_value_reviews as review
  where review.id = p_request_id
  for update;

  if not found then raise exception 'Solicitação de revisão não encontrada.'; end if;
  if not exists (
    select 1 from public.crm_property_reviewability as reviewability
    where reviewability.property_id = request_row.property_id
      and reviewability.reviewable
  ) then
    raise exception 'Este imóvel não está mais marcado como revisável.';
  end if;
  if p_decision not in ('keep', 'change') then
    raise exception 'Escolha manter ou alterar o valor.';
  end if;
  if p_decision = 'change' and coalesce(p_new_value, 0) <= 0 then
    raise exception 'Informe o novo valor do imóvel.';
  end if;

  update public.crm_property_value_reviews as review
  set decision = p_decision,
      new_value = case when p_decision = 'change' then p_new_value else null end,
      change_note = case when p_decision = 'change'
        then nullif(trim(coalesce(p_change_note, '')), '') else null end,
      review_text = trim(p_review_text),
      sonialima_note = nullif(trim(coalesce(p_sonialima_note, '')), ''),
      responded_at = now(),
      responded_by = auth.uid(),
      approval_status = case when p_decision = 'change' then 'pending' else 'not_required' end,
      approved_value = null,
      approved_by = null,
      approved_at = null
  where review.id = p_request_id
  returning * into request_row;

  -- Somente Thiago e Vitor recebem a solicitação operacional de revisão.
  if p_decision = 'change' then
    formatted_current := case when request_row.current_value is null then 'não informado'
      else 'R$ ' || to_char(request_row.current_value, 'FM999G999G999G990D00') end;
    formatted_new := 'R$ ' || to_char(p_new_value, 'FM999G999G999G990D00');

    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select
      profile.id,
      'property_value_review',
      'Revisão de imóvel solicitada pelo SoniaLima',
      'Revise o imóvel ' || request_row.property_title || '. Valor atual: '
        || formatted_current || '. Valor proposto: ' || formatted_new
        || '. Texto revisado: ' || request_row.review_text
        || case when request_row.sonialima_note is null then ''
          else '. Observação do SoniaLima: ' || request_row.sonialima_note end,
      '/imoveis',
      jsonb_build_object(
        'reviewRequestId', request_row.id,
        'propertyId', request_row.property_id,
        'propertyTitle', request_row.property_title,
        'currentValue', request_row.current_value,
        'proposedValue', request_row.new_value,
        'reviewText', request_row.review_text,
        'sonialimaNote', request_row.sonialima_note,
        'publicUrl', request_row.public_url
      )
    from public.profiles as profile
    where profile.role = 'broker'
      and lower(trim(profile.email)) in (
        'crmthiago@sonialima.com.br',
        'unassigned-operator@example.invalid'
      );
  end if;

  return request_row;
end;
$$;

revoke all on function public.respond_property_value_review_details(
  uuid, text, numeric, text, text, text
) from public, anon;
grant execute on function public.respond_property_value_review_details(
  uuid, text, numeric, text, text, text
) to authenticated;

-- Mantém o lembrete do SoniaLima toda quinta-feira às 14h de Brasília.
do $$
declare existing_job bigint;
begin
  for existing_job in
    select jobid from cron.job where jobname = 'weekly-property-value-reviews'
  loop
    perform cron.unschedule(existing_job);
  end loop;
end;
$$;
select cron.schedule(
  'weekly-property-value-reviews',
  '0 17 * * 4',
  $$select public.process_weekly_property_value_reviews();$$
);

commit;
