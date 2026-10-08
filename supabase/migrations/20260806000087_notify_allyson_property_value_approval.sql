-- A proposta de novo valor gera uma notificacao pessoal para o Allyson aprovar no CRM.
create or replace function public.notify_allyson_property_value_approval()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  allyson_id uuid;
  notification_body text;
begin
  if new.decision <> 'change' or new.approval_status <> 'pending' then
    return new;
  end if;

  select profile.id into allyson_id
  from public.profiles as profile
  where profile.role = 'admin'
    and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  limit 1;

  if allyson_id is null then
    return new;
  end if;

  notification_body := 'O acessocrm propos alterar o valor do imovel '
    || new.property_title || ' de '
    || case
      when new.current_value is null then 'valor nao informado'
      else 'R$ ' || to_char(new.current_value, 'FM999G999G999G990D00')
    end
    || ' para R$ ' || to_char(new.new_value, 'FM999G999G999G990D00')
    || '. Abra a Validacao para aprovar ou ajustar o valor antes de aplicar no CRM.';

  -- Se a proposta for respondida novamente, substitui o aviso antigo pela versao atual.
  delete from public.crm_notification_outbox as notification
  where notification.recipient_id = allyson_id
    and notification.kind = 'property_value_approval'
    and notification.payload ->> 'reviewRequestId' = new.id::text;

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    allyson_id,
    'property_value_approval',
    'Aprovar novo valor do imovel',
    notification_body,
    '/validacao',
    jsonb_build_object(
      'reviewRequestId', new.id,
      'propertyId', new.property_id,
      'propertyTitle', new.property_title,
      'currentValue', new.current_value,
      'proposedValue', new.new_value,
      'changeNote', new.change_note,
      'publicUrl', new.public_url
    )
  );

  return new;
end;
$$;

drop trigger if exists crm_property_value_review_notify_allyson
  on public.crm_property_value_reviews;
create trigger crm_property_value_review_notify_allyson
after insert or update of decision, new_value, change_note, approval_status
on public.crm_property_value_reviews
for each row execute function public.notify_allyson_property_value_approval();

-- Inclui propostas que ja estavam aguardando aprovacao quando esta correcao entrou.
insert into public.crm_notification_outbox (
  recipient_id,
  kind,
  title,
  body,
  url,
  payload
)
select
  allyson.id,
  'property_value_approval',
  'Aprovar novo valor do imovel',
  'O acessocrm propos alterar o valor do imovel ' || review.property_title
    || '. Abra a Validacao para aprovar ou ajustar o valor antes de aplicar no CRM.',
  '/validacao',
  jsonb_build_object(
    'reviewRequestId', review.id,
    'propertyId', review.property_id,
    'propertyTitle', review.property_title,
    'currentValue', review.current_value,
    'proposedValue', review.new_value,
    'changeNote', review.change_note,
    'publicUrl', review.public_url
  )
from public.crm_property_value_reviews as review
join public.profiles as allyson
  on allyson.role = 'admin'
 and lower(trim(allyson.email)) = 'crmsoniaallyson@gmail.com'
where review.decision = 'change'
  and review.approval_status = 'pending'
  and not exists (
    select 1
    from public.crm_notification_outbox as notification
    where notification.recipient_id = allyson.id
      and notification.kind = 'property_value_approval'
      and notification.payload ->> 'reviewRequestId' = review.id::text
  );

revoke all on function public.notify_allyson_property_value_approval()
  from public, anon, authenticated;
