begin;

alter table public.crm_property_value_reviews
  add column if not exists review_text_requested boolean not null default false;

create or replace function public.respond_property_value_review_details(
  p_request_id uuid,
  p_decision text,
  p_new_value numeric,
  p_change_note text,
  p_review_text text,
  p_sonialima_note text,
  p_review_text_requested boolean
)
returns public.crm_property_value_reviews
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  request_row public.crm_property_value_reviews;
begin
  request_row := public.respond_property_value_review_details(
    p_request_id,
    p_decision,
    p_new_value,
    p_change_note,
    case
      when coalesce(p_review_text_requested, false)
        then coalesce(nullif(trim(coalesce(p_review_text, '')), ''), 'Revisar o texto atual do anúncio.')
      else 'Sem revisão de texto solicitada.'
    end,
    p_sonialima_note
  );

  update public.crm_property_value_reviews as review
  set review_text_requested = coalesce(p_review_text_requested, false),
      review_text = case when coalesce(p_review_text_requested, false)
        then nullif(trim(coalesce(p_review_text, '')), '') else null end
  where review.id = p_request_id
  returning * into request_row;

  -- Uma revisão apenas textual também avisa exclusivamente Thiago e Vitor.
  if coalesce(p_review_text_requested, false) and p_decision <> 'change' then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select
      profile.id,
      'property_value_review',
      'Revisão de texto solicitada pelo SoniaLima',
      'Revise o texto do imóvel ' || request_row.property_title
        || case when request_row.review_text is null then '.'
          else '. Sugestão: ' || request_row.review_text end
        || case when request_row.sonialima_note is null then ''
          else '. Observação do SoniaLima: ' || request_row.sonialima_note end,
      '/imoveis',
      jsonb_build_object(
        'reviewRequestId', request_row.id,
        'propertyId', request_row.property_id,
        'propertyTitle', request_row.property_title,
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
  uuid, text, numeric, text, text, text, boolean
) from public, anon;
grant execute on function public.respond_property_value_review_details(
  uuid, text, numeric, text, text, text, boolean
) to authenticated;

commit;
