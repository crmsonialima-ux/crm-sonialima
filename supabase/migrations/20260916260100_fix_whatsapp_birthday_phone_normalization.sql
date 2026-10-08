-- Use a stable short constraint name and correct normalized phone dispatching.
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conrelid='public.crm_whatsapp_birthday_dispatches'::regclass
      and conname='crm_whatsapp_birthday_dispatche_recipient_key_birthday_year_key'
  ) then
    alter table public.crm_whatsapp_birthday_dispatches
      rename constraint crm_whatsapp_birthday_dispatche_recipient_key_birthday_year_key to crm_birthday_dispatch_unique;
  end if;
end;
$$;

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


