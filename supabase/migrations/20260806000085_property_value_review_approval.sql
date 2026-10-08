-- A alteracao proposta pelo acessocrm so chega ao CRM depois da aprovacao do Allyson.
alter table public.crm_property_value_reviews
  add column if not exists approval_status text not null default 'not_required',
  add column if not exists approved_value numeric,
  add column if not exists approved_by uuid references public.profiles(id),
  add column if not exists approved_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'crm_property_value_reviews_approval_status_check'
      and conrelid = 'public.crm_property_value_reviews'::regclass
  ) then
    alter table public.crm_property_value_reviews
      add constraint crm_property_value_reviews_approval_status_check
      check (approval_status in ('not_required', 'pending', 'approved'));
  end if;
end;
$$;

update public.crm_property_value_reviews
set approval_status = 'pending'
where decision = 'change'
  and approval_status = 'not_required';

create index if not exists crm_property_value_reviews_approval_idx
  on public.crm_property_value_reviews(approval_status, requested_at desc);

create or replace function public.respond_property_value_review(
  p_request_id uuid,
  p_decision text,
  p_new_value numeric,
  p_change_note text
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
    raise exception 'Somente o acessocrm pode responder a revisao de valores.';
  end if;

  select * into request_row
  from public.crm_property_value_reviews
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitacao de revisao nao encontrada.';
  end if;
  if not exists (
    select 1
    from public.crm_property_reviewability as reviewability
    where reviewability.property_id = request_row.property_id
      and reviewability.reviewable
  ) then
    raise exception 'Este imovel nao esta mais marcado como revisavel.';
  end if;
  if p_decision not in ('keep', 'change') then
    raise exception 'Escolha manter ou alterar o valor.';
  end if;
  if p_decision = 'change' and coalesce(p_new_value, 0) <= 0 then
    raise exception 'Informe o novo valor do imovel.';
  end if;

  update public.crm_property_value_reviews
  set decision = p_decision,
      new_value = case when p_decision = 'change' then p_new_value else null end,
      change_note = case
        when p_decision = 'change' then nullif(trim(coalesce(p_change_note, '')), '')
        else null
      end,
      responded_at = now(),
      responded_by = auth.uid(),
      approval_status = case when p_decision = 'change' then 'pending' else 'not_required' end,
      approved_value = null,
      approved_by = null,
      approved_at = null
  where id = p_request_id
  returning * into request_row;

  if p_decision = 'change' then
    formatted_current := case
      when request_row.current_value is null then 'nao informado'
      else 'R$ ' || to_char(request_row.current_value, 'FM999G999G999G990D00')
    end;
    formatted_new := 'R$ ' || to_char(p_new_value, 'FM999G999G999G990D00');

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload
    )
    select distinct
      profile.id,
      'property_portal_price_update',
      'Atualizar preco e foto nos portais',
      'O imovel ' || request_row.property_title
        || ' teve alteracao proposta de ' || formatted_current || ' para ' || formatted_new
        || '. Atualize o preco na DF Imoveis e nos demais portais e altere a foto.'
        || case
          when request_row.change_note is null then ''
          else ' Observacao: ' || request_row.change_note || '.'
        end,
      '/imoveis',
      jsonb_build_object(
        'reviewRequestId', request_row.id,
        'propertyId', request_row.property_id,
        'propertyTitle', request_row.property_title,
        'currentValue', request_row.current_value,
        'proposedValue', request_row.new_value,
        'changeNote', request_row.change_note,
        'publicUrl', request_row.public_url
      )
    from public.crm_property_broker_access as access
    join public.profiles as profile
      on profile.id = access.broker_id
     and profile.role = 'broker'
    where access.property_id = request_row.property_id;
  end if;

  return request_row;
end;
$$;

create or replace function public.approve_property_value_review(
  p_request_id uuid,
  p_approved_value numeric
)
returns public.crm_property_value_reviews
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  request_row public.crm_property_value_reviews;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente o Allyson pode aprovar a alteracao no CRM.';
  end if;
  if coalesce(p_approved_value, 0) <= 0 then
    raise exception 'Informe um valor valido para o imovel.';
  end if;

  select * into request_row
  from public.crm_property_value_reviews
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitacao de revisao nao encontrada.';
  end if;
  if request_row.decision <> 'change' or request_row.approval_status <> 'pending' then
    raise exception 'Esta alteracao nao esta aguardando aprovacao.';
  end if;

  update public.crm_property_value_reviews
  set approval_status = 'approved',
      approved_value = p_approved_value,
      approved_by = auth.uid(),
      approved_at = now()
  where id = p_request_id
  returning * into request_row;

  update public.crm_property_catalog
  set value = p_approved_value,
      updated_at = now()
  where external_id = request_row.property_id;

  return request_row;
end;
$$;

revoke all on function public.respond_property_value_review(uuid, text, numeric, text)
  from public, anon;
grant execute on function public.respond_property_value_review(uuid, text, numeric, text)
  to authenticated;
revoke all on function public.approve_property_value_review(uuid, numeric)
  from public, anon;
grant execute on function public.approve_property_value_review(uuid, numeric)
  to authenticated;
