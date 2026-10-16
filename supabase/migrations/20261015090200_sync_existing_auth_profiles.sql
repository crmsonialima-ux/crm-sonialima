-- Garante perfil no CRM para todas as contas que já existem no Supabase Auth.
insert into public.profiles (id, full_name, email, role)
select
  user_row.id,
  coalesce(nullif(user_row.raw_user_meta_data ->> 'full_name', ''), split_part(user_row.email, '@', 1)),
  coalesce(user_row.email, ''),
  case
    when user_row.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid then 'admin'::public.crm_role
    else 'broker'::public.crm_role
  end
from auth.users as user_row
on conflict (id) do update
set email = excluded.email,
    full_name = case
      when public.profiles.full_name = '' then excluded.full_name
      else public.profiles.full_name
    end,
    role = excluded.role,
    updated_at = now();
