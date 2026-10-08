-- Revisao semanal de valores dos imoveis marcados como revisaveis.
drop policy if exists "Non accesscrm users read property reviewability"
  on public.crm_property_reviewability;
create policy "Authenticated users read property reviewability"
  on public.crm_property_reviewability
  for select
  using (auth.uid() is not null);

create table if not exists public.crm_property_value_reviews (
  id uuid primary key default gen_random_uuid(),
  property_id text not null,
  review_week date not null,
  property_title text not null,
  property_address text,
  public_url text,
  current_value numeric,
  decision text not null default 'pending'
    check (decision in ('pending', 'keep', 'change')),
  new_value numeric,
  change_note text,
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  responded_by uuid references public.profiles(id),
  unique (property_id, review_week)
);

create index if not exists crm_property_value_reviews_requested_idx
  on public.crm_property_value_reviews(requested_at desc);
create index if not exists crm_property_value_reviews_pending_idx
  on public.crm_property_value_reviews(decision, requested_at desc);

alter table public.crm_property_value_reviews enable row level security;
grant select on public.crm_property_value_reviews to authenticated;

create policy "Accesscrm and Allyson read property value reviews"
  on public.crm_property_value_reviews
  for select
  using (public.is_restricted_admin() or public.is_allyson_admin());

create or replace function public.crm_property_review_week()
returns date
language sql
stable
set search_path = pg_catalog
as $$
  select (
    date_trunc('week', timezone('America/Sao_Paulo', now())) + interval '3 days'
  )::date;
$$;

create or replace function public.process_weekly_property_value_reviews()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  accesscrm_id uuid;
  property_row record;
  request_id uuid;
  created_count integer := 0;
begin
  select profile.id into accesscrm_id
  from public.profiles as profile
  where profile.role = 'admin'
    and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  limit 1;

  if accesscrm_id is null then
    raise exception 'Conta unassigned-institutional@example.invalid nao encontrada.';
  end if;

  for property_row in
    select
      reviewability.property_id,
      coalesce(catalog.title, responsibility.title, reviewability.property_id) as title,
      catalog.address,
      catalog.value,
      link.url
    from public.crm_property_reviewability as reviewability
    left join public.crm_property_catalog as catalog
      on catalog.external_id = reviewability.property_id
    left join public.crm_property_document_responsibilities as responsibility
      on responsibility.external_id = reviewability.property_id
    left join public.crm_property_public_links as link
      on link.property_id = reviewability.property_id
    where reviewability.reviewable
  loop
    request_id := null;
    insert into public.crm_property_value_reviews (
      property_id,
      review_week,
      property_title,
      property_address,
      public_url,
      current_value
    ) values (
      property_row.property_id,
      public.crm_property_review_week(),
      property_row.title,
      property_row.address,
      property_row.url,
      property_row.value
    )
    on conflict (property_id, review_week) do nothing
    returning id into request_id;

    if request_id is null then
      continue;
    end if;

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload
    ) values (
      accesscrm_id,
      'property_value_review',
      'Revisar valor do imovel',
      'O imovel ' || property_row.title
        || ' esta marcado como revisavel. Confirme se o valor sera mantido ou alterado.',
      '/imoveis',
      jsonb_build_object(
        'reviewRequestId', request_id,
        'propertyId', property_row.property_id,
        'propertyTitle', property_row.title,
        'currentValue', property_row.value,
        'publicUrl', property_row.url,
        'reviewWeek', public.crm_property_review_week()
      )
    );
    created_count := created_count + 1;
  end loop;

  return created_count;
end;
$$;

create or replace function public.ensure_property_value_review(
  p_property_id text,
  p_property_title text,
  p_property_address text,
  p_current_value numeric,
  p_public_url text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  request_id uuid;
begin
  if not public.is_restricted_admin() then
    raise exception 'Somente o acessocrm pode responder a revisao de valores.';
  end if;

  if not exists (
    select 1
    from public.crm_property_reviewability as reviewability
    where reviewability.property_id = p_property_id
      and reviewability.reviewable
  ) then
    raise exception 'Este imovel nao esta marcado como revisavel.';
  end if;

  insert into public.crm_property_value_reviews (
    property_id,
    review_week,
    property_title,
    property_address,
    public_url,
    current_value
  ) values (
    p_property_id,
    public.crm_property_review_week(),
    coalesce(nullif(trim(p_property_title), ''), p_property_id),
    nullif(trim(coalesce(p_property_address, '')), ''),
    nullif(trim(coalesce(p_public_url, '')), ''),
    p_current_value
  )
  on conflict (property_id, review_week) do update set
    property_title = excluded.property_title,
    property_address = excluded.property_address,
    public_url = excluded.public_url,
    current_value = case
      when public.crm_property_value_reviews.decision = 'pending'
        then excluded.current_value
      else public.crm_property_value_reviews.current_value
    end
  returning id into request_id;

  return request_id;
end;
$$;

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
      change_note = nullif(trim(coalesce(p_change_note, '')), ''),
      responded_at = now(),
      responded_by = auth.uid()
  where id = p_request_id
  returning * into request_row;

  if p_decision = 'change' then
    update public.crm_property_catalog
    set value = p_new_value,
        updated_at = now()
    where external_id = request_row.property_id;
  end if;

  return request_row;
end;
$$;

revoke all on function public.process_weekly_property_value_reviews()
  from public, anon, authenticated;
grant execute on function public.process_weekly_property_value_reviews()
  to service_role;
revoke all on function public.ensure_property_value_review(text, text, text, numeric, text)
  from public, anon;
grant execute on function public.ensure_property_value_review(text, text, text, numeric, text)
  to authenticated;
revoke all on function public.respond_property_value_review(uuid, text, numeric, text)
  from public, anon;
grant execute on function public.respond_property_value_review(uuid, text, numeric, text)
  to authenticated;

do $$
declare
  existing_job bigint;
begin
  for existing_job in
    select jobid from cron.job where jobname = 'weekly-property-value-reviews'
  loop
    perform cron.unschedule(existing_job);
  end loop;
end;
$$;

-- pg_cron usa UTC: 17h UTC corresponde a 14h em America/Sao_Paulo.
select cron.schedule(
  'weekly-property-value-reviews',
  '0 17 * * 4',
  $$select public.process_weekly_property_value_reviews();$$
);
