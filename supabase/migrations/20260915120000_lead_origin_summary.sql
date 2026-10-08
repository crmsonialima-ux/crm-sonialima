begin;

-- Share only aggregate counts; access to individual leads remains unchanged.
create or replace function public.crm_lead_origin_summary(
  p_start timestamptz default null,
  p_end timestamptz default null
)
returns table(channel text, source_portal text, total bigint)
language sql
stable
security definer
set search_path = public
as $$
  select l.channel, l.source_portal, count(*)
  from public.crm_leads l
  where exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role in ('admin', 'broker')
  )
    and (p_start is null or l.created_at >= p_start)
    and (p_end is null or l.created_at < p_end)
  group by l.channel, l.source_portal;
$$;

revoke all on function public.crm_lead_origin_summary(timestamptz, timestamptz) from public, anon;
grant execute on function public.crm_lead_origin_summary(timestamptz, timestamptz) to authenticated;

commit;
