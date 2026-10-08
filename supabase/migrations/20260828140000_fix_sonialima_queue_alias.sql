begin;

-- SoniaLima possui registro exclusivamente na fila de Venda. Portanto a
-- elegibilidade especial nao precisa consultar queue.lead_type; remover essa
-- referencia tambem evita alias fora de escopo em trechos internos das RPCs.
do $$
declare signature text; definition text; patched text;
begin
  foreach signature in array array[
    'public.create_distributed_lead(text,text,text,text,text,text,text,text,text,numeric,text)',
    'public.process_expired_lead_assignments()',
    'public.restart_exhausted_lead_queue(uuid)',
    'public.accept_lead_assignment(uuid)'
  ] loop
    select pg_get_functiondef(signature::regprocedure) into definition;
    patched := replace(
      definition,
      '(profile.role = ''broker'' or (queue.lead_type = ''Venda'' and lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''))',
      '(profile.role = ''broker'' or lower(trim(profile.email)) = ''unassigned-institutional@example.invalid'')'
    );
    if patched is distinct from definition then
      execute patched;
    end if;
  end loop;
end;
$$;

commit;
