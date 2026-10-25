-- OKFlow answers store. Run in the Supabase SQL Editor (new query, paste, Run). Running it
-- again after an update is safe: it keeps every answer and only adds or replaces the rest.
--
-- Every swipe adds one row. A changed answer is a newer row for the same card, so
-- nothing is ever overwritten. Each phone or browser signs in anonymously, so the
-- rows from one labeller share an ID without anyone making an account.
--
-- What the public web page can do, through the publishable (anon) key:
--   * add answers, only under its own anonymous ID;
--   * read the leaderboard: names and card counts, nothing else;
--   * make a one-time code to continue on another device, and use one: the new
--     device is then counted as the same person and gets that person's latest answers.
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

-- Several devices, one person. Each device signs in anonymously and gets its own labeller id;
-- a device that uses a code made on another device is linked to that device's person. A person
-- is the labeller id of their first device, so a device that was never linked is its own person.
create table if not exists public.okflow_people (
  labeller  uuid primary key,          -- a device's anonymous sign-in
  person    uuid not null,             -- the labeller id of the person's first device
  linked_at timestamptz not null default now()
);
create table if not exists public.okflow_codes (
  code       text primary key,         -- 8 hex characters, shown as XXXX-XXXX
  person     uuid not null,
  set_id     text not null,
  expires_at timestamptz not null
);
alter table public.okflow_people enable row level security;
alter table public.okflow_codes enable row level security;
revoke all on table public.okflow_people, public.okflow_codes from public, anon, authenticated;

create or replace function public.okflow_person(p_labeller uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.person from public.okflow_people p where p.labeller = p_labeller), p_labeller)
$$;
revoke all on function public.okflow_person(uuid) from public, anon, authenticated;

-- The leaderboard: per person, the latest name they typed and how many cards they answered.
-- "me" marks the caller's own row; no IDs leave the database.
create or replace function public.okflow_board(p_set text)
returns table (name text, cards bigint, me boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select (array_agg(a.name order by a.answered_at desc, a.seq desc))[1],
         count(distinct a.card),
         bool_or(coalesce(p.person, a.labeller) = public.okflow_person((select auth.uid())))
  from public.okflow_answers a
  left join public.okflow_people p on p.labeller = a.labeller
  where a.set_id = p_set
  group by coalesce(p.person, a.labeller)
  order by 2 desc
  limit 200
$$;
revoke all on function public.okflow_board(text) from public, anon, authenticated;
grant execute on function public.okflow_board(text) to authenticated;

-- A one-time code for continuing on another device: valid 15 minutes, replaces any earlier code.
create or replace function public.okflow_make_code(p_set text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  who uuid := public.okflow_person((select auth.uid()));
  c text;
begin
  if who is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  delete from public.okflow_codes k where k.expires_at < now() or k.person = who;
  c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.okflow_codes (code, person, set_id, expires_at)
    values (c, who, p_set, now() + interval '15 minutes');
  return c;
end
$$;
revoke all on function public.okflow_make_code(text) from public, anon, authenticated;
grant execute on function public.okflow_make_code(text) to authenticated;

-- Use a code: links the calling device to the code's person (along with any devices linked to
-- it so far) and returns that person's latest answer to each card of the set, with their latest name.
create or replace function public.okflow_use_code(p_code text, p_set text)
returns table (name text, card text, answer text, decide_ms integer, answered_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  who uuid;
  nm text;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  delete from public.okflow_codes k
    where k.code = upper(replace(trim(p_code), '-', '')) and k.set_id = p_set and k.expires_at >= now()
    returning k.person into who;
  if who is null then
    raise exception 'unknown or expired code' using errcode = 'P0002';
  end if;
  if who <> public.okflow_person(me) then
    update public.okflow_people set person = who, linked_at = now() where person = me;
    insert into public.okflow_people (labeller, person) values (me, who)
      on conflict (labeller) do update set person = excluded.person, linked_at = now();
  end if;
  select a.name into nm
    from public.okflow_answers a left join public.okflow_people p on p.labeller = a.labeller
    where a.set_id = p_set and coalesce(p.person, a.labeller) = who
    order by a.answered_at desc, a.seq desc limit 1;
  return query
    select distinct on (a.card) coalesce(nm, ''), a.card, a.answer, a.decide_ms, a.answered_at
    from public.okflow_answers a left join public.okflow_people p on p.labeller = a.labeller
    where a.set_id = p_set and coalesce(p.person, a.labeller) = who
    order by a.card, a.answered_at desc, a.seq desc;
end
$$;
revoke all on function public.okflow_use_code(text, text) from public, anon, authenticated;
grant execute on function public.okflow_use_code(text, text) to authenticated;
