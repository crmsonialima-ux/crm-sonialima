begin;

delete from public.lead_distribution_queue
where lead_type = 'Aluguel'
  and broker_id = (
    select id
    from public.profiles
    where lower(full_name) like '%derley%'
       or lower(email) like '%derley%'
    limit 1
  );

commit;
