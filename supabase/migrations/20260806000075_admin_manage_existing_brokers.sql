-- A equipe comercial e formada exclusivamente por usuarios reais do Supabase.
-- A presenca nas filas de Venda e Aluguel representa um corretor ativo no CRM.

begin;

create or replace function public.list_broker_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
security definer
set search_path = public
as $$
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where profile.role = 'broker'
    and exists (
      select 1
      from public.lead_distribution_queue as queue
      where queue.broker_id = profile.id
        and queue.lead_type = 'Venda'
    )
    and exists (
      select 1
      from public.lead_distribution_queue as queue
      where queue.broker_id = profile.id
        and queue.lead_type = 'Aluguel'
    )
  order by profile.full_name, profile.email;
$$;

revoke all on function public.list_broker_profiles() from public, anon;
grant execute on function public.list_broker_profiles() to authenticated;

create or replace function public.admin_list_broker_candidates()
returns table (
  id uuid,
  full_name text,
  email text,
  whatsapp_phone text
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Apenas administradores podem consultar usuarios para a equipe comercial.';
  end if;

  return query
  select
    auth_user.id,
    coalesce(
      nullif(trim(profile.full_name), ''),
      nullif(trim(auth_user.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(auth_user.email, ''), '@', 1), ''),
      'Usuario do Supabase'
    ) as full_name,
    coalesce(nullif(trim(profile.email), ''), auth_user.email, '') as email,
    nullif(regexp_replace(coalesce(profile.whatsapp_phone, ''), '\D', '', 'g'), '') as whatsapp_phone
  from auth.users as auth_user
  left join public.profiles as profile on profile.id = auth_user.id
  where auth_user.email is not null
    and trim(auth_user.email) <> ''
    and auth_user.email_confirmed_at is not null
    and auth_user.deleted_at is null
    and (auth_user.banned_until is null or auth_user.banned_until <= now())
    and (profile.id is null or (
      profile.role = 'broker'
      and not coalesce(profile.is_validator, false)
    ))
    and (
      not exists (
        select 1
        from public.lead_distribution_queue as queue
        where queue.broker_id = auth_user.id
          and queue.lead_type = 'Venda'
      )
      or not exists (
        select 1
        from public.lead_distribution_queue as queue
        where queue.broker_id = auth_user.id
          and queue.lead_type = 'Aluguel'
      )
    )
  order by 2, 3;
end;
$$;

revoke all on function public.admin_list_broker_candidates()
  from public, anon, authenticated;
grant execute on function public.admin_list_broker_candidates()
  to authenticated;

create or replace function public.admin_add_existing_broker(
  p_user_id uuid,
  p_whatsapp_phone text default null
)
returns table (id uuid, full_name text, email text, role text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  auth_user record;
  existing_profile record;
  normalized_phone text;
  queue_type text;
  next_position integer;
  effective_name text;
  effective_email text;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Apenas administradores podem adicionar corretores.';
  end if;

  select
    crm_user.id,
    crm_user.email,
    crm_user.raw_user_meta_data,
    crm_user.email_confirmed_at,
    crm_user.deleted_at,
    crm_user.banned_until
  into auth_user
  from auth.users as crm_user
  where crm_user.id = p_user_id;

  if not found then
    raise exception 'O usuario informado nao esta cadastrado no Supabase.';
  end if;
  if auth_user.email_confirmed_at is null then
    raise exception 'Confirme o e-mail do usuario no Supabase antes de adiciona-lo.';
  end if;
  if auth_user.deleted_at is not null
     or (auth_user.banned_until is not null and auth_user.banned_until > now()) then
    raise exception 'Este usuario esta excluido ou bloqueado no Supabase.';
  end if;

  select profile.role, profile.is_validator, profile.full_name,
    profile.email, profile.whatsapp_phone
  into existing_profile
  from public.profiles as profile
  where profile.id = p_user_id;

  if found and (
    existing_profile.role = 'admin'
    or coalesce(existing_profile.is_validator, false)
  ) then
    raise exception 'Usuarios administradores ou de validacao nao podem ser adicionados como corretores.';
  end if;

  effective_name := coalesce(
    nullif(trim(existing_profile.full_name), ''),
    nullif(trim(auth_user.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(auth_user.email, ''), '@', 1), ''),
    'Corretor'
  );
  effective_email := coalesce(nullif(trim(existing_profile.email), ''), auth_user.email, '');
  normalized_phone := regexp_replace(
    coalesce(nullif(trim(p_whatsapp_phone), ''), existing_profile.whatsapp_phone, ''),
    '\D',
    '',
    'g'
  );

  if normalized_phone !~ '^55[1-9][0-9]{9,10}$' then
    raise exception 'Informe o WhatsApp com DDI 55, DDD e numero, totalizando 12 ou 13 digitos.';
  end if;

  insert into public.profiles as target (id, full_name, email, role, whatsapp_phone)
  values (p_user_id, effective_name, effective_email, 'broker', normalized_phone)
  on conflict on constraint profiles_pkey do update
  set full_name = case
        when nullif(trim(target.full_name), '') is null then excluded.full_name
        else target.full_name
      end,
      email = excluded.email,
      whatsapp_phone = excluded.whatsapp_phone,
      updated_at = now()
  where target.role = 'broker'
    and not coalesce(target.is_validator, false);

  if not found then
    raise exception 'O perfil informado nao pode ser ativado como corretor.';
  end if;

  foreach queue_type in array array['Venda'::text, 'Aluguel'::text]
  loop
    perform pg_advisory_xact_lock(hashtext('lead-distribution:' || queue_type));

    if exists (
      select 1
      from public.lead_distribution_queue as queue
      where queue.lead_type = queue_type
        and queue.broker_id = p_user_id
    ) then
      update public.lead_distribution_queue
      set broker_email = effective_email,
          updated_at = now()
      where lead_type = queue_type
        and broker_id = p_user_id;
    else
      select coalesce(max(queue.position), 0) + 1
      into next_position
      from public.lead_distribution_queue as queue
      where queue.lead_type = queue_type;

      insert into public.lead_distribution_queue (
        lead_type,
        broker_id,
        position,
        broker_email
      ) values (
        queue_type,
        p_user_id,
        next_position,
        effective_email
      );
    end if;
  end loop;

  perform public.append_crm_audit_event(
    p_user_id,
    auth.uid(),
    'broker',
    'broker_added_to_team',
    'active',
    'broker',
    p_user_id,
    null,
    now(),
    'Corretor adicionado a equipe comercial',
    jsonb_build_object(
      'email', effective_email,
      'whatsappPhone', normalized_phone,
      'queues', jsonb_build_array('Venda', 'Aluguel')
    ),
    null,
    null
  );

  return query
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where profile.id = p_user_id;
end;
$$;

revoke all on function public.admin_add_existing_broker(uuid, text)
  from public, anon, authenticated;
grant execute on function public.admin_add_existing_broker(uuid, text)
  to authenticated;

create or replace function public.admin_remove_broker_from_team(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  broker_profile record;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Apenas administradores podem remover corretores da equipe.';
  end if;

  select profile.id, profile.full_name, profile.email, profile.role, profile.is_validator
  into broker_profile
  from public.profiles as profile
  where profile.id = p_user_id;

  if not found or broker_profile.role <> 'broker'
     or coalesce(broker_profile.is_validator, false) then
    raise exception 'Corretor ativo nao encontrado.';
  end if;

  if (
    select count(distinct queue.broker_id)
    from public.lead_distribution_queue as queue
    join public.profiles as profile on profile.id = queue.broker_id
    where profile.role = 'broker'
      and exists (
        select 1
        from public.lead_distribution_queue as sale_queue
        where sale_queue.broker_id = queue.broker_id
          and sale_queue.lead_type = 'Venda'
      )
      and exists (
        select 1
        from public.lead_distribution_queue as rental_queue
        where rental_queue.broker_id = queue.broker_id
          and rental_queue.lead_type = 'Aluguel'
      )
  ) <= 1 then
    raise exception 'Nao e possivel remover o ultimo corretor ativo das filas.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:Venda'));
  perform pg_advisory_xact_lock(hashtext('lead-distribution:Aluguel'));

  delete from public.lead_distribution_queue
  where broker_id = p_user_id;

  perform public.append_crm_audit_event(
    p_user_id,
    auth.uid(),
    'broker',
    'broker_removed_from_team',
    'inactive',
    'broker',
    p_user_id,
    null,
    now(),
    'Corretor removido das filas comerciais',
    jsonb_build_object(
      'email', broker_profile.email,
      'profilePreserved', true,
      'historyPreserved', true
    ),
    null,
    null
  );
end;
$$;

revoke all on function public.admin_remove_broker_from_team(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_remove_broker_from_team(uuid)
  to authenticated;

commit;
