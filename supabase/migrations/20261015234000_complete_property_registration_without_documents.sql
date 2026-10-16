begin;

-- The capture form and required document stage were retired. Existing
-- properties should not retain a pending stage that no longer has an action.
update public.crm_property_catalog
set registration_phase = 'COMPLETED'
where registration_phase = 'PENDING';

commit;
