-- Integrações com a service role continuam podendo registrar leads; a restrição
-- de edição por etapa é aplicada às sessões dos corretores.
create or replace function public.enforce_broker_stage_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_allyson_admin() or auth.role() = 'service_role' then return new; end if;
  if old.owner_id <> auth.uid() then
    raise exception 'Você só pode atualizar os seus próprios leads.';
  end if;
  if (to_jsonb(new) - array['stage', 'updated_at'])
     is distinct from
     (to_jsonb(old) - array['stage', 'updated_at']) then
    raise exception 'Corretores podem alterar somente a etapa do próprio lead.';
  end if;
  return new;
end;
$$;
