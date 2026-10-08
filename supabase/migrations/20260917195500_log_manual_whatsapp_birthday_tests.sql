begin;

create table if not exists public.crm_whatsapp_birthday_manual_tests (
  id uuid primary key default gen_random_uuid(),
  recipient_name text not null,
  recipient_phone text not null,
  birthday_year integer not null check (birthday_year between 2000 and 9999),
  status text not null check (status in ('sent', 'failed')),
  meta_message_id text,
  meta_status jsonb,
  attempted_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists crm_whatsapp_birthday_manual_tests_created_idx
  on public.crm_whatsapp_birthday_manual_tests (created_at desc);

alter table public.crm_whatsapp_birthday_manual_tests enable row level security;
revoke all on public.crm_whatsapp_birthday_manual_tests from public, anon, authenticated;

commit;
