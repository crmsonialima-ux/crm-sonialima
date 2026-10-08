-- Relatorio mensal de vendas e esteira de entrega/pós-venda.
create table public.crm_sales (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.profiles(id),
  capturer_id uuid references public.profiles(id),
  capturer_name text not null,
  buyer_name text not null,
  buyer_email text,
  buyer_phone text,
  buyer_birth_date date,
  property_address text not null,
  sold_on date not null,
  contract_signed_on date,
  deed_on date,
  expected_delivery_at timestamptz not null,
  delivered_at timestamptz,
  has_financing boolean not null default false,
  financial_submitted_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_sales_delivery_order check (delivered_at is null or delivered_at >= sold_on::timestamptz)
);
create index crm_sales_month_idx on public.crm_sales(sold_on desc);
create index crm_sales_delivery_idx on public.crm_sales(delivered_at) where delivered_at is not null;
alter table public.crm_sales enable row level security;
grant select on public.crm_sales to authenticated;
create policy "Sales visible to seller and sales operators" on public.crm_sales
  for select to authenticated using (
    seller_id = auth.uid() or exists (
      select 1 from public.profiles p where p.id = auth.uid()
      and lower(p.email) in ('unassigned-operator@example.invalid', 'crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid')
    )
  );

-- Financial data is physically separate: Vitor can submit it, but cannot SELECT it.
create table public.crm_sale_financials (
  sale_id uuid primary key references public.crm_sales(id) on delete cascade,
  purchase_price numeric(15,2) not null check (purchase_price >= 0),
  commission_amount numeric(15,2) not null check (commission_amount >= 0),
  submitted_at timestamptz not null default now(),
  submitted_by uuid not null references public.profiles(id)
);
alter table public.crm_sale_financials enable row level security;
grant select on public.crm_sale_financials to authenticated;
create policy "Only Allyson and AcessoCRM see sale amounts" on public.crm_sale_financials
  for select to authenticated using (exists (
    select 1 from public.profiles p where p.id = auth.uid()
    and lower(p.email) in ('crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid')
  ));

create or replace function public.save_crm_sale(p_sale_id uuid, p_values jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  actor_email text;
  v_sale_id uuid;
  seller uuid;
  capturer uuid;
  expected_at timestamptz;
  actual_at timestamptz;
  price numeric;
  commission numeric;
  existing_financial boolean;
begin
  select lower(email) into actor_email from public.profiles where id = auth.uid();
  if actor_email not in ('unassigned-operator@example.invalid', 'crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid') then
    raise exception 'Sem permissao para preencher vendas.';
  end if;
  seller := nullif(p_values->>'seller_id','')::uuid;
  capturer := nullif(p_values->>'capturer_id','')::uuid;
  expected_at := nullif(p_values->>'expected_delivery_at','')::timestamptz;
  actual_at := nullif(p_values->>'delivered_at','')::timestamptz;
  if seller is null or not exists (select 1 from public.profiles where id = seller and role = 'broker') then
    raise exception 'Selecione um corretor valido.';
  end if;
  if capturer is not null and not exists (select 1 from public.profiles where id = capturer) then
    raise exception 'Captador invalido.';
  end if;
  if nullif(trim(p_values->>'buyer_name'),'') is null
    or nullif(trim(p_values->>'property_address'),'') is null
    or nullif(trim(p_values->>'capturer_name'),'') is null
    or nullif(p_values->>'sold_on','') is null or expected_at is null then
    raise exception 'Preencha comprador, imovel, captador, venda e entrega prevista.';
  end if;
  if nullif(p_values->>'buyer_email','') is not null
     and p_values->>'buyer_email' !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'E-mail do comprador invalido.';
  end if;
  if actual_at is not null and actual_at < (p_values->>'sold_on')::date::timestamptz then
    raise exception 'A entrega nao pode anteceder a venda.';
  end if;
  if p_sale_id is null then
    insert into public.crm_sales (
      seller_id,capturer_id,capturer_name,buyer_name,buyer_email,buyer_phone,buyer_birth_date,
      property_address,sold_on,contract_signed_on,deed_on,expected_delivery_at,delivered_at,
      has_financing,created_by
    ) values (
      seller,capturer,trim(p_values->>'capturer_name'),trim(p_values->>'buyer_name'),
      nullif(trim(p_values->>'buyer_email'),''),nullif(trim(p_values->>'buyer_phone'),''),
      nullif(p_values->>'buyer_birth_date','')::date,trim(p_values->>'property_address'),
      (p_values->>'sold_on')::date,nullif(p_values->>'contract_signed_on','')::date,
      nullif(p_values->>'deed_on','')::date,expected_at,actual_at,
      coalesce((p_values->>'has_financing')::boolean,false),auth.uid()
    ) returning id into v_sale_id;
  else
    update public.crm_sales set seller_id=seller,capturer_id=capturer,
      capturer_name=trim(p_values->>'capturer_name'),buyer_name=trim(p_values->>'buyer_name'),
      buyer_email=nullif(trim(p_values->>'buyer_email'),''),buyer_phone=nullif(trim(p_values->>'buyer_phone'),''),
      buyer_birth_date=nullif(p_values->>'buyer_birth_date','')::date,
      property_address=trim(p_values->>'property_address'),sold_on=(p_values->>'sold_on')::date,
      contract_signed_on=nullif(p_values->>'contract_signed_on','')::date,
      deed_on=nullif(p_values->>'deed_on','')::date,expected_delivery_at=expected_at,
      delivered_at=actual_at,has_financing=coalesce((p_values->>'has_financing')::boolean,false),
      updated_at=now()
    where id=p_sale_id returning id into v_sale_id;
    if v_sale_id is null then raise exception 'Venda nao encontrada.'; end if;
  end if;

  select exists(select 1 from public.crm_sale_financials f where f.sale_id=v_sale_id)
    into existing_financial;
  if p_values ? 'purchase_price' or p_values ? 'commission_amount' then
    if existing_financial and actor_email='unassigned-operator@example.invalid' then
      raise exception 'Valores enviados. Somente Allyson e AcessoCRM podem alterar ou consultar.';
    end if;
    price := nullif(p_values->>'purchase_price','')::numeric;
    commission := nullif(p_values->>'commission_amount','')::numeric;
    if price is null or commission is null then raise exception 'Informe valor da venda e comissao juntos.'; end if;
    insert into public.crm_sale_financials(sale_id,purchase_price,commission_amount,submitted_by)
    values(v_sale_id,price,commission,auth.uid())
    on conflict (sale_id) do update set purchase_price=excluded.purchase_price,
      commission_amount=excluded.commission_amount,submitted_at=now(),submitted_by=auth.uid();
    update public.crm_sales set financial_submitted_at=now() where id=v_sale_id;
  end if;
  return v_sale_id;
end; $$;
revoke all on function public.save_crm_sale(uuid,jsonb) from public,anon;
grant execute on function public.save_crm_sale(uuid,jsonb) to authenticated;

alter table public.crm_agenda_entries
  add column if not exists source_sale_id uuid references public.crm_sales(id) on delete cascade,
  add column if not exists sale_task_kind text,
  add column if not exists sale_task_due_at timestamptz,
  add column if not exists sale_documents_completed_at timestamptz,
  add column if not exists sale_reminder_30_sent_at timestamptz;
create unique index crm_agenda_sale_task_unique on public.crm_agenda_entries(source_sale_id,sale_task_kind)
  where source_sale_id is not null;

create table public.crm_sale_delivery_documents (
  sale_id uuid not null references public.crm_sales(id) on delete cascade,
  document_kind text not null check (document_kind in ('neoenergia','condominio','caesb','iptu')),
  storage_path text not null,
  file_name text not null,
  uploaded_by uuid not null references public.profiles(id),
  uploaded_at timestamptz not null default now(),
  primary key (sale_id,document_kind)
);
alter table public.crm_sale_delivery_documents enable row level security;
grant select on public.crm_sale_delivery_documents to authenticated;
create policy "Sale delivery documents visible to aftercare team" on public.crm_sale_delivery_documents
  for select to authenticated using (exists (
    select 1 from public.profiles p where p.id=auth.uid()
    and lower(p.email) in ('unassigned-agenda@example.invalid','crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid')
  ));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('sale-delivery-documents','sale-delivery-documents',false,10485760,
  array['application/pdf','image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy "Aftercare reads sale documents" on storage.objects for select to authenticated
  using (bucket_id='sale-delivery-documents' and exists (
    select 1 from public.profiles p where p.id=auth.uid() and lower(p.email) in
    ('unassigned-agenda@example.invalid','crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid')
  ));
create policy "Aftercare uploads sale documents" on storage.objects for insert to authenticated
  with check (bucket_id='sale-delivery-documents' and exists (
    select 1 from public.profiles p where p.id=auth.uid() and lower(p.email) in
    ('unassigned-agenda@example.invalid','crmsoniaallyson@gmail.com')
  ) and exists (select 1 from public.crm_sales s where s.id::text=(storage.foldername(name))[1]));

create or replace function public.save_sale_delivery_document(
  p_sale_id uuid,p_document_kind text,p_storage_path text,p_file_name text
) returns void language plpgsql security definer set search_path=pg_catalog,public,storage as $$
declare actor_email text; total integer; finished_at timestamptz; aftercare uuid; sale_row public.crm_sales;
begin
  select lower(email) into actor_email from public.profiles where id=auth.uid();
  if actor_email not in ('unassigned-agenda@example.invalid','crmsoniaallyson@gmail.com') then
    raise exception 'Somente Derley ou Allyson podem anexar.';
  end if;
  if p_document_kind not in ('neoenergia','condominio','caesb','iptu') then raise exception 'Documento invalido.'; end if;
  select * into sale_row from public.crm_sales where id=p_sale_id for update;
  if not found or sale_row.delivered_at is null or sale_row.delivered_at>now() then
    raise exception 'A entrega ainda nao foi registrada.';
  end if;
  if split_part(p_storage_path,'/',1) <> p_sale_id::text
    or not exists(select 1 from storage.objects where bucket_id='sale-delivery-documents' and name=p_storage_path and owner_id=auth.uid()::text) then
    raise exception 'Arquivo enviado nao encontrado.';
  end if;
  insert into public.crm_sale_delivery_documents(sale_id,document_kind,storage_path,file_name,uploaded_by)
  values(p_sale_id,p_document_kind,p_storage_path,left(p_file_name,255),auth.uid())
  on conflict(sale_id,document_kind) do update set storage_path=excluded.storage_path,
    file_name=excluded.file_name,uploaded_by=auth.uid(),uploaded_at=now();
  select count(*) into total from public.crm_sale_delivery_documents where sale_id=p_sale_id;
  if total=4 then
    select sale_documents_completed_at into finished_at from public.crm_agenda_entries
    where source_sale_id=p_sale_id and sale_task_kind='transfer';
    if finished_at is null then
      finished_at:=now();
      update public.crm_agenda_entries set sale_documents_completed_at=finished_at,
        feedback_at=finished_at, feedback_note='Quatro comprovantes anexados',updated_at=now()
      where source_sale_id=p_sale_id and sale_task_kind='transfer';
      select id into aftercare from public.profiles where lower(email)='unassigned-institutional@example.invalid' limit 1;
      if aftercare is null then raise exception 'Perfil AcessoCRM nao encontrado.'; end if;
      insert into public.crm_agenda_entries(category,scheduled_at,observation,target_user_id,created_by,
        source_kind,source_sale_id,sale_task_kind)
      values('observacao',finished_at+interval '7 days',
        'Pos-venda: ligar para '||sale_row.buyer_name||' ('||coalesce(sale_row.buyer_phone,'sem telefone')||')' || E'\nImovel: '||sale_row.property_address,
        aftercare,auth.uid(),'sale_followup',p_sale_id,'followup')
      on conflict (source_sale_id,sale_task_kind) where source_sale_id is not null do nothing;
    end if;
  end if;
end; $$;
revoke all on function public.save_sale_delivery_document(uuid,text,text,text) from public,anon;
grant execute on function public.save_sale_delivery_document(uuid,text,text,text) to authenticated;

create or replace function public.process_crm_sale_automation()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare s public.crm_sales; seller_entry uuid; derley uuid; item record; processed integer:=0;
begin
  select id into derley from public.profiles where lower(email)='unassigned-agenda@example.invalid' limit 1;
  for s in select * from public.crm_sales loop
    -- Seller sees the scheduled handover even before delivery is confirmed.
    insert into public.crm_agenda_entries(category,scheduled_at,observation,target_user_id,created_by,
      source_kind,source_sale_id,sale_task_kind)
    values('observacao',coalesce(s.delivered_at,s.expected_delivery_at),
      'Entrega do imovel a '||s.buyer_name||E'\nImovel: '||s.property_address,
      s.seller_id,s.created_by,'sale_delivery',s.id,'seller')
    on conflict (source_sale_id,sale_task_kind) where source_sale_id is not null
    do update set scheduled_at=excluded.scheduled_at,observation=excluded.observation,
      target_user_id=excluded.target_user_id,
      reminder_sent_at=case when public.crm_agenda_entries.scheduled_at is distinct from excluded.scheduled_at
        then null else public.crm_agenda_entries.reminder_sent_at end,
      sale_reminder_30_sent_at=case when public.crm_agenda_entries.scheduled_at is distinct from excluded.scheduled_at
        then null else public.crm_agenda_entries.sale_reminder_30_sent_at end
    where public.crm_agenda_entries.scheduled_at is distinct from excluded.scheduled_at
      or public.crm_agenda_entries.observation is distinct from excluded.observation
      or public.crm_agenda_entries.target_user_id is distinct from excluded.target_user_id
    returning id into seller_entry;
    if derley is not null and s.delivered_at is not null and s.delivered_at<=now() then
      insert into public.crm_agenda_entries(category,scheduled_at,observation,target_user_id,created_by,
        source_kind,source_sale_id,sale_task_kind,sale_task_due_at)
      values('observacao',s.delivered_at,
        'Transferencias apos entrega: Neoenergia, condominio, CAESB e IPTU.'||E'\nCliente: '||s.buyer_name||
        E'\nImovel: '||s.property_address,derley,s.created_by,'sale_transfer',s.id,'transfer',
        s.delivered_at+interval '48 hours')
      on conflict (source_sale_id,sale_task_kind) where source_sale_id is not null do nothing;
      if found then
        insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
        values(derley,'sale_delivery','Imovel entregue: transferencias em 48h',
          s.buyer_name||' - '||s.property_address,'/agenda',jsonb_build_object('saleId',s.id));
      end if;
    end if;
  end loop;
  for item in select id,target_user_id,observation from public.crm_agenda_entries
    where source_kind='sale_delivery' and sale_reminder_30_sent_at is null
      and scheduled_at>now() and scheduled_at<=now()+interval '30 minutes'
    for update skip locked
  loop
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    values(item.target_user_id,'sale_delivery_reminder','Entrega em 30 minutos',
      item.observation,'/agenda',jsonb_build_object('agendaId',item.id));
    update public.crm_agenda_entries set sale_reminder_30_sent_at=now() where id=item.id;
    processed:=processed+1;
  end loop;
  return processed;
end; $$;
revoke all on function public.process_crm_sale_automation() from public,anon,authenticated;
grant execute on function public.process_crm_sale_automation() to service_role;
select cron.schedule('crm-sale-automation','* * * * *',
  $$select public.process_crm_sale_automation();$$);
