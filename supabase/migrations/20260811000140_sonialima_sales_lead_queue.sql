begin;

-- O acesso CRM permanece administrador, mas aparece nas selecoes comerciais
-- com o nome institucional SoniaLima.
create or replace function public.list_broker_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select profile.id,
    case when lower(trim(profile.email))='unassigned-institutional@example.invalid' then 'SoniaLima'
         else profile.full_name end,
    profile.email, profile.role::text
  from public.profiles as profile
  where profile.role='broker'
     or (profile.role='admin' and lower(trim(profile.email))='unassigned-institutional@example.invalid')
  order by 2, profile.email;
$$;

create or replace function public.sync_property_broker_access(p_property_id text,p_broker_names text[])
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare normalized_property_id text:=nullif(trim(p_property_id),'');
  normalized_broker_names text[]:=coalesce(p_broker_names,'{}'::text[]);
begin
  if not public.can_manage_property_brokers() then raise exception 'Somente Allyson e o acesso CRM podem alterar os corretores responsaveis.'; end if;
  if normalized_property_id is null then raise exception 'Identificador do imovel e obrigatorio.'; end if;
  if cardinality(normalized_broker_names)=0 then raise exception 'Selecione ao menos um corretor responsavel.'; end if;
  delete from public.crm_property_broker_access where property_id=normalized_property_id;
  insert into public.crm_property_broker_access(property_id,broker_id)
  select distinct normalized_property_id,profile.id from public.profiles profile
  where (profile.role='broker' and profile.full_name=any(normalized_broker_names))
     or (lower(trim(profile.email))='unassigned-institutional@example.invalid' and 'SoniaLima'=any(normalized_broker_names));
  if (select count(*) from public.crm_property_broker_access where property_id=normalized_property_id)
     <> cardinality(normalized_broker_names) then raise exception 'Um ou mais corretores selecionados nao foram encontrados.'; end if;
  update public.crm_property_catalog set brokers=array_to_string(normalized_broker_names,', '),updated_at=now()
  where external_id=normalized_property_id;
  if not found then raise exception 'Imovel nao encontrado.'; end if;
end; $$;

-- Insere SoniaLima exclusivamente na fila de Venda e garante ausencia em Aluguel.
delete from public.lead_distribution_queue q using public.profiles p
where q.broker_id=p.id and lower(trim(p.email))='unassigned-institutional@example.invalid' and q.lead_type<>'Venda';
insert into public.lead_distribution_queue(lead_type,broker_id,broker_email,position)
select 'Venda',p.id,'SoniaLima',coalesce((select max(position)+1 from public.lead_distribution_queue where lead_type='Venda'),1)
from public.profiles p where lower(trim(p.email))='unassigned-institutional@example.invalid'
on conflict (lead_type,broker_id) do update set broker_email='SoniaLima';

-- As funcoes atuais da esteira usam sempre os aliases queue/profile. A excecao
-- abaixo conserva todos os demais filtros (bloqueio e acesso ao imovel).
do $$
declare signature text; definition text;
begin
  foreach signature in array array[
    'public.create_distributed_lead(text,text,text,text,text,text,text,text,text,numeric,text)',
    'public.process_expired_lead_assignments()',
    'public.restart_exhausted_lead_queue(uuid)',
    'public.accept_lead_assignment(uuid)'
  ] loop
    select pg_get_functiondef(signature::regprocedure) into definition;
    if position('profile.role = ''broker''' in definition)=0 then
      raise exception 'Filtro esperado nao encontrado em %',signature;
    end if;
    definition:=replace(definition,
      'profile.role = ''broker''',
      '(profile.role = ''broker'' or (queue.lead_type = ''Venda'' and lower(trim(profile.email)) = ''unassigned-institutional@example.invalid''))');
    execute definition;
  end loop;
end $$;

revoke all on function public.list_broker_profiles(),public.sync_property_broker_access(text,text[]) from public,anon;
grant execute on function public.list_broker_profiles(),public.sync_property_broker_access(text,text[]) to authenticated;

commit;
