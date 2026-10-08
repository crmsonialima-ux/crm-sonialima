-- Annual WhatsApp birthday dispatches. Financial and contact data remain server-only.
create table if not exists public.crm_whatsapp_birthday_dispatches (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.crm_sales(id) on delete cascade,
  recipient_key text not null,
  recipient_name text not null,
  recipient_phone text not null,
  birthday_year integer not null check (birthday_year between 2000 and 9999),
  status text not null check (status in ('queued','sent','failed','skipped')),
  meta_message_id text,
  meta_status jsonb,
  attempted_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_birthday_dispatch_unique unique (recipient_key, birthday_year)
);

create index if not exists crm_whatsapp_birthday_dispatches_queue_idx
  on public.crm_whatsapp_birthday_dispatches(status, birthday_year, created_at);

alter table public.crm_whatsapp_birthday_dispatches enable row level security;
revoke all on public.crm_whatsapp_birthday_dispatches from public, anon, authenticated;

create or replace function public.claim_crm_birthday_dispatches(p_local_date date default (now() at time zone 'America/Sao_Paulo')::date)
returns table (
  dispatch_id uuid,
  sale_id uuid,
  recipient_name text,
  recipient_phone text,
  birthday_year integer
)
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  sale_row record;
  normalized_phone text;
  normalized_key text;
  dispatch_row public.crm_whatsapp_birthday_dispatches%rowtype;
begin
  for sale_row in
    select sale.id, sale.buyer_name, sale.buyer_phone, sale.buyer_birth_date
    from public.crm_sales sale
    where sale.buyer_birth_date is not null
      and extract(month from sale.buyer_birth_date) = extract(month from p_local_date)
      and extract(day from sale.buyer_birth_date) = extract(day from p_local_date)
      and nullif(regexp_replace(coalesce(sale.buyer_phone,''), '[^0-9]', '', 'g'),'') is not null
    order by sale.created_at asc
  loop
    normalized_phone:=regexp_replace(sale_row.buyer_phone, '[^0-9]', '', 'g');
    if normalized_phone ~ '^[1-9][0-9]{9,10}$' then normalized_phone:='55'||normalized_phone; end if;
    if normalized_phone !~ '^55[1-9][0-9]{10,11}$' then
      continue;
    end if;
    normalized_key:=normalized_phone;

    insert into public.crm_whatsapp_birthday_dispatches(
      sale_id,recipient_key,recipient_name,recipient_phone,birthday_year,status
    ) values (
      sale_row.id,normalized_key,trim(sale_row.buyer_name),normalized_phone,extract(year from p_local_date)::integer,'queued'
    ) on conflict on constraint crm_birthday_dispatch_unique do nothing
    returning * into dispatch_row;

    if found then
      dispatch_id:=dispatch_row.id;
      sale_id:=dispatch_row.sale_id;
      recipient_name:=dispatch_row.recipient_name;
      recipient_phone:=dispatch_row.recipient_phone;
      birthday_year:=dispatch_row.birthday_year;
      return next;
    end if;
  end loop;
end;
$$;

create or replace function public.record_crm_birthday_dispatch(
  p_dispatch_id uuid,
  p_status text,
  p_meta_message_id text default null,
  p_meta_status jsonb default null
)
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  if p_status not in ('sent','failed','skipped') then
    raise exception 'Status de envio invalido.';
  end if;
  update public.crm_whatsapp_birthday_dispatches
  set status=p_status,
      meta_message_id=nullif(trim(p_meta_message_id),''),
      meta_status=p_meta_status,
      attempted_at=now(),
      sent_at=case when p_status='sent' then now() else null end,
      updated_at=now()
  where id=p_dispatch_id and status='queued';
end;
$$;

revoke all on function public.claim_crm_birthday_dispatches(date) from public,anon,authenticated;
revoke all on function public.record_crm_birthday_dispatch(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.claim_crm_birthday_dispatches(date) to service_role;
grant execute on function public.record_crm_birthday_dispatch(uuid,text,text,jsonb) to service_role;




