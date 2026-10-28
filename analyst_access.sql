-- Read-only access for the lab's analysis scripts. Run in the Supabase SQL Editor; rerunning is safe.
--
-- The login is made without a password, so it can't connect until you give it one. Do that once, in a
-- separate query typed straight into the SQL Editor (never saved in this file or anywhere in git):
--
--     alter role okflow_reader with password 'your-long-password';
--
-- (the password goes between the single quotes; the same line changes it later). Keep the connection
-- string with that password only on the analysis computers (see scripts/fetch_okflow.py in the
-- analysis repository).
--
-- The login can read the answers, the device links and who said they're a Weiss Lab member
-- (never their email), and can't change anything.

do $$
begin
  if not exists (select from pg_roles where rolname = 'okflow_reader') then
    create role okflow_reader with login;
  end if;
end
$$;
alter role okflow_reader set default_transaction_read_only = on;
grant usage on schema public to okflow_reader;
grant select on table public.okflow_answers, public.okflow_people to okflow_reader;
grant select (labeller, member, signed_at) on table public.okflow_signups to okflow_reader;

-- Row-level security is on for these tables; this login sees every row.
drop policy if exists "analysis reads all answers" on public.okflow_answers;
create policy "analysis reads all answers" on public.okflow_answers for select to okflow_reader using (true);
drop policy if exists "analysis reads all links" on public.okflow_people;
create policy "analysis reads all links" on public.okflow_people for select to okflow_reader using (true);
drop policy if exists "analysis reads all signups" on public.okflow_signups;
create policy "analysis reads all signups" on public.okflow_signups for select to okflow_reader using (true);
