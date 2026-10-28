-- Read-only access for the lab's analysis scripts. Run in the Supabase SQL Editor, after
-- replacing CHOOSE-A-LONG-PASSWORD with a long random password of your own (the password is
-- only used the first time, when the login is made; rerunning is safe and keeps it).
-- Never commit the password: keep it only in the analysis computer's local settings.
--
-- The login can read the answers, the device links and who said they're a Weiss Lab member
-- (never their email), and can't change anything.

do $$
begin
  if not exists (select from pg_roles where rolname = 'okflow_reader') then
    create role okflow_reader with login password 'CHOOSE-A-LONG-PASSWORD';
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
