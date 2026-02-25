-- OPTIMIZATION: Ensure Realtime events send the full row
-- Run this if UI updates are receiving empty payloads or missing data

ALTER TABLE public.user_clipboards REPLICA IDENTITY FULL;

-- Double check Realtime is enabled for this table
-- (You usually do this in the Dashboard > Database > Replication, but here is SQL just in case)
begin;
  drop publication if exists supabase_realtime;
  create publication supabase_realtime for table public.user_clipboards;
commit;
