begin;

-- The isolated notification laboratory already writes accepted_at, but the
-- column was missing from its test-only attempts table.
alter table public.crm_assignment_test_attempts
  add column if not exists accepted_at timestamptz;

commit;
