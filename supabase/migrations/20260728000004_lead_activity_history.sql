-- Histórico imutável de cada etapa e observação do atendimento.
create table if not exists public.crm_lead_activities (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  stage text not null,
  note text,
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists crm_lead_activities_lead_created_idx
  on public.crm_lead_activities(lead_id, created_at desc);

alter table public.crm_lead_activities enable row level security;
grant select, insert on public.crm_lead_activities to authenticated;

create policy "Admins read every lead activity; brokers read their own lead activity"
  on public.crm_lead_activities for select
  using (
    public.is_admin()
    or exists (
      select 1 from public.crm_leads
      where crm_leads.id = crm_lead_activities.lead_id
        and crm_leads.owner_id = auth.uid()
    )
  );

create policy "Admins and lead owners add lead activity"
  on public.crm_lead_activities for insert
  with check (
    author_id = auth.uid()
    and (
      public.is_admin()
      or exists (
        select 1 from public.crm_leads
        where crm_leads.id = crm_lead_activities.lead_id
          and crm_leads.owner_id = auth.uid()
      )
    )
  );
