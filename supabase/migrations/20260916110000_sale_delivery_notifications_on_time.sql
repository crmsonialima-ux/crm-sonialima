-- A entrega tem hora marcada: o aviso de 30 minutos e a abertura da demanda
-- precisam aparecer mesmo quando ocorrerem fora do expediente comercial.
create or replace function public.crm_apply_notification_business_hours()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare event_moment timestamptz;
begin
  if new.kind in ('sale_delivery','sale_delivery_reminder')
     or (new.kind='lead_assignment' and coalesce((new.payload->>'manualRelease')::boolean,false)) then
    new.available_at:=coalesce(new.available_at,now());
    return new;
  end if;
  if tg_op='UPDATE' and new.kind is not distinct from old.kind
    and new.created_at is not distinct from old.created_at
    and new.available_at is not distinct from old.available_at then
    return new;
  end if;
  event_moment:=coalesce(new.created_at,now());
  new.available_at:=public.crm_next_business_moment(
    greatest(coalesce(new.available_at,event_moment),event_moment)
  );
  return new;
end; $$;
