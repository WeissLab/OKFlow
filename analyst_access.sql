-- Read-only access for the lab's analysis scripts. Run once in the Supabase SQL Editor,
-- after replacing CHOOSE-A-LONG-PASSWORD with a long random password of your own.
-- Never commit the password: keep it only in the analysis computer's local settings.
--
-- The login can read the answers and the device links, nothing else, and can't change anything.

create role okflow_reader with login password 'CHOOSE-A-LONG-PASSWORD';
alter role okflow_reader set default_transaction_read_only = on;
grant usage on schema public to okflow_reader;
grant select on table public.okflow_answers, public.okflow_people to okflow_reader;

-- Row-level security is on for both tables; this login sees every row.
drop policy if exists "analysis reads all answers" on public.okflow_answers;
create policy "analysis reads all answers" on public.okflow_answers for select to okflow_reader using (true);
drop policy if exists "analysis reads all links" on public.okflow_people;
create policy "analysis reads all links" on public.okflow_people for select to okflow_reader using (true);
