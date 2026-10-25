-- OKFlow answers store. Run once in the Supabase SQL Editor (new query, paste, Run).
--
-- Every swipe adds one row. A changed answer is a newer row for the same card, so
-- nothing is ever overwritten. Each phone or browser signs in anonymously, so the
-- rows from one labeller share an ID without anyone making an account.
--
-- What the public web page can do, through the publishable (anon) key:
--   * add answers, only under its own anonymous ID;
--   * read the leaderboard: names and card counts, nothing else.
-- It cannot read, change or delete any answer. Read everything from the
-- Supabase dashboard (Table Editor > okflow_answers > Export to CSV).

create table if not exists public.okflow_answers (
  id          uuid primary key,                      -- made by the page, so a resent answer is stored once
  set_id      text not null check (length(set_id) between 1 and 40),
  labeller    uuid not null default auth.uid(),      -- the anonymous sign-in
  name        text not null default '' check (length(name) <= 60),
  card        text not null check (card ~ '^[0-9]{1,4}(h|v|hv)?b?$'),
  answer      text not null check (answer in ('keep', 'toss', 'unsure')),
  decide_ms   integer check (decide_ms between 0 and 86400000),
  seq         integer not null check (seq >= 0),     -- the labeller's answer count, orders revisions
  answered_at timestamptz not null,                  -- the phone's clock
  received_at timestamptz not null default now()     -- the server's clock
);
create index if not exists okflow_answers_set_labeller on public.okflow_answers (set_id, labeller);

alter table public.okflow_answers enable row level security;
revoke all on table public.okflow_answers from public, anon, authenticated;
grant insert on table public.okflow_answers to authenticated;
-- A resent answer is skipped by its id (insert ... on conflict (id) do nothing). Postgres
-- needs SELECT on that column and a select policy for it, so each labeller can see the
-- ids of their own answers, and nothing else.
grant select (id) on table public.okflow_answers to authenticated;

drop policy if exists "add own answers" on public.okflow_answers;
create policy "add own answers" on public.okflow_answers
  for insert to authenticated
  with check (labeller = (select auth.uid()));
drop policy if exists "see own answer ids" on public.okflow_answers;
create policy "see own answer ids" on public.okflow_answers
  for select to authenticated
  using (labeller = (select auth.uid()));

-- The leaderboard: per labeller, the latest name they typed and how many cards they answered.
-- "me" marks the caller's own row; no IDs leave the database.
create or replace function public.okflow_board(p_set text)
returns table (name text, cards bigint, me boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select (array_agg(a.name order by a.seq desc))[1],
         count(distinct a.card),
         bool_or(a.labeller = (select auth.uid()))
  from public.okflow_answers a
  where a.set_id = p_set
  group by a.labeller
  order by 2 desc
  limit 200
$$;
revoke all on function public.okflow_board(text) from public, anon, authenticated;
grant execute on function public.okflow_board(text) to authenticated;
