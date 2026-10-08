-- Execute após a migration de acesso para importar os leads já existentes da planilha sem duplicá-los.

alter table public.crm_leads
  add column if not exists external_id text unique;

alter table public.crm_leads
  alter column stage set default 'Novo';

update public.crm_leads
set stage = 'Novo'
where stage = 'Lead';
