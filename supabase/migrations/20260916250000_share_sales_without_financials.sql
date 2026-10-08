-- Todos os corretores e administradores podem acompanhar as vendas.
-- Valores permanecem exclusivamente em crm_sale_financials, protegida por RLS.
drop policy if exists "Sales visible to seller and sales operators" on public.crm_sales;

create policy "Sales visible to all CRM users" on public.crm_sales
  for select to authenticated
  using (
    exists (
      select 1
      from public.profiles profile
      where profile.id = auth.uid()
        and profile.role in ('broker', 'admin')
    )
  );
