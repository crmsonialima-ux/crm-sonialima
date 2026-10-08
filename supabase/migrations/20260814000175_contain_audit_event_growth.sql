-- Contem a tempestade de telemetria sem remover auditoria comercial.
-- O mesmo erro de cliente, para o mesmo usuario/rota, gera no maximo um
-- registro por hora. Os detalhes aceitos sao resumidos no servidor.

create or replace function public.record_crm_client_error(
  p_area text,
  p_operation text,
  p_message text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_area text := left(coalesce(nullif(trim(p_area), ''), 'client'), 80);
  normalized_operation text := left(coalesce(nullif(trim(p_operation), ''), 'Operacao no CRM'), 300);
  normalized_message text := left(nullif(trim(coalesce(p_message, '')), ''), 2000);
  normalized_route text := left(coalesce(p_details ->> 'route', ''), 300);
  safe_details jsonb;
  dedupe text;
begin
  if normalized_message is null then
    raise exception 'Informe a mensagem do erro.';
  end if;

  safe_details := jsonb_strip_nulls(jsonb_build_object(
    'route', nullif(normalized_route, ''),
    'queryKey', left((p_details -> 'queryKey')::text, 1000),
    'mutationKey', left((p_details -> 'mutationKey')::text, 1000),
    'boundary', left(p_details ->> 'boundary', 200),
    'filename', left(p_details ->> 'filename', 500),
    'line', left(p_details ->> 'line', 40),
    'column', left(p_details ->> 'column', 40),
    'userAgent', left(p_details ->> 'userAgent', 500),
    'stack', left(p_details ->> 'stack', 2000),
    'firstSeenAt', left(coalesce(p_details ->> 'happenedAt', now()::text), 100)
  ));

  dedupe := 'client-error:v2:' || md5(concat_ws('|',
    coalesce(auth.uid()::text, 'anonymous'),
    normalized_area,
    normalized_operation,
    normalized_message,
    normalized_route,
    to_char(date_trunc('hour', now()), 'YYYYMMDDHH24')
  ));

  return public.append_crm_audit_event(
    auth.uid(), auth.uid(), 'error', 'client_error', 'error',
    normalized_area, null, null, now(), normalized_operation,
    safe_details, normalized_message, dedupe
  );
end;
$$;

revoke all on function public.record_crm_client_error(text,text,text,jsonb)
  from public, anon;
grant execute on function public.record_crm_client_error(text,text,text,jsonb)
  to authenticated;

-- A tela de validacao deve ser paginada. Zero nao pode solicitar a tabela
-- inteira, pois isso transforma uma falha de auditoria em nova falha de carga.
do $$
declare
  function_definition text;
begin
  select pg_get_functiondef('public.get_validation_audit(uuid,integer)'::regprocedure::oid)
  into function_definition;

  function_definition := replace(
    function_definition,
    'case when p_limit is null or p_limit <= 0 then null else p_limit end',
    'least(greatest(coalesce(p_limit, 500), 1), 1000)'
  );
  execute function_definition;
end;
$$;
