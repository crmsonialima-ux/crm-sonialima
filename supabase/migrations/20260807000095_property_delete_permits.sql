-- Emite autorizações curtas e específicas para a exclusão de imóveis no Apps Script.
create schema if not exists private;
revoke all on schema private from public;

create table if not exists private.property_delete_signing_secret (
  singleton boolean primary key default true check (singleton),
  secret text not null check (length(secret) >= 32),
  updated_at timestamptz not null default now()
);

revoke all on table private.property_delete_signing_secret from public, anon, authenticated;

create or replace function public.issue_property_delete_permit(p_property_id text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  signing_secret text;
  expires_at bigint := floor(extract(epoch from clock_timestamp()))::bigint + 120;
  signed_message text;
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas crmsoniaallyson@gmail.com pode excluir imóveis.';
  end if;

  if normalized_property_id is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;

  select secret
  into signing_secret
  from private.property_delete_signing_secret
  where singleton = true;

  if signing_secret is null then
    raise exception 'A autorização de exclusão ainda não foi configurada.';
  end if;

  signed_message := normalized_property_id || '|' || expires_at::text;

  return jsonb_build_object(
    'expiresAt', expires_at,
    'signature', encode(
      extensions.hmac(
        convert_to(signed_message, 'UTF8'),
        convert_to(signing_secret, 'UTF8'),
        'sha256'
      ),
      'hex'
    )
  );
end;
$$;

revoke all on function public.issue_property_delete_permit(text)
  from public, anon;
grant execute on function public.issue_property_delete_permit(text)
  to authenticated, service_role;
