-- OKFlow answers store. Run in the Supabase SQL Editor (new query, paste, Run). Running it
-- again after an update is safe: it keeps every answer and only adds or replaces the rest.
--
-- Every swipe adds one row. A changed answer is a newer row for the same card, so
-- nothing is ever overwritten. Each phone or browser signs in anonymously, so the
-- rows from one labeller share an ID without anyone making an account.
--
-- What the public web page can do, through the publishable (anon) key:
--   * on the lab page: say whether the person is a Weiss Lab member and leave an email (okflow_signups),
--     then add answers to a lab set, only under its own anonymous ID, and only once that device has
--     said "member";
--   * on the study page (?study): read a study set's settings, consent (which returns a private deletion
--     code), add answers to that set under the consent, get a new deletion code, withdraw (with the code
--     from any device, or from a linked device), and add or remove an email for the end-of-study summary;
--   * read the leaderboard: card counts under scrambled handles, never names;
--   * make a one-time code to continue on another device, and use one: the new
--     device is then counted as the same person and gets that person's latest answers;
--     with "move here" the device that made the code is let go and can't add answers;
--   * read back its own person's latest answers, so linked devices stay in step;
--   * read per-cell progress (counts only), to hand out the cells closest to ready.
-- It cannot read, change or delete any answer (withdrawal deletes the person's own study answers).
-- Names and emails are cleaned and checked here before they are stored (near the end of this file).
-- Read everything with the analysis login (analyst_access.sql) or from the Supabase dashboard.
--
-- The study's part (from "Sets and their settings" on) was first run on the live project in five parts in
-- the SQL Editor on 2026-10-29; this file now holds all of it.

-- The page reaches the schema through the Data API. Granted here rather than relying on Supabase's
-- defaults, so it holds on a project made with "Automatically expose new tables" off; every table and
-- function below still grants only what the page needs.
grant usage on schema public to anon, authenticated;

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

-- Who may label. The REB found that labelling for the public is research with human participants,
-- so until it approves the public version, only Weiss Lab members label. On each device the person
-- says whether they're a member and gives an email: a member's email lets that device add answers,
-- anyone else's is kept to tell them when the public version opens. Every answer adds a row; a
-- device's latest row is the one that counts. The page can add rows under its own id, never read them.
create table if not exists public.okflow_signups (
  id        uuid primary key,                        -- made by the page, so a resent row is stored once
  labeller  uuid not null default auth.uid(),
  email     text not null check (length(email) between 3 and 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  member    boolean not null,                        -- true: says they're a member of the Weiss Lab
  signed_at timestamptz not null default now()
);
-- The device's id on the Supabase project it used before, when OKFlow moved to a new project (the page sends
-- it with the device's first signup here); okflow_link_previous, below, links the two ids as one person.
alter table public.okflow_signups add column if not exists previous_labeller uuid;
alter table public.okflow_signups enable row level security;
revoke all on table public.okflow_signups from public, anon, authenticated;
grant insert on table public.okflow_signups to authenticated;
grant select (id) on table public.okflow_signups to authenticated;   -- for "on conflict (id) do nothing", as below
drop policy if exists "add own signup" on public.okflow_signups;
create policy "add own signup" on public.okflow_signups
  for insert to authenticated
  with check (labeller = (select auth.uid()));
drop policy if exists "see own signup ids" on public.okflow_signups;
create policy "see own signup ids" on public.okflow_signups
  for select to authenticated
  using (labeller = (select auth.uid()));

-- Is the calling device's latest answer "member of the Weiss Lab"? Used by the rule on adding answers.
create or replace function public.okflow_is_member()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.member from public.okflow_signups s where s.labeller = (select auth.uid())
                   order by s.signed_at desc limit 1), false)
$$;
revoke all on function public.okflow_is_member() from public, anon, authenticated;
grant execute on function public.okflow_is_member() to authenticated;

-- Devices let go with "move here": the person carries on on the new device, and the old one can't add
-- answers. Its earlier answers stay the person's. The page clears its storage and starts it afresh.
create table if not exists public.okflow_released (
  labeller    uuid primary key,          -- the device let go
  by_device   uuid not null,             -- the device that took over
  released_at timestamptz not null default now()
);
alter table public.okflow_released enable row level security;
revoke all on table public.okflow_released from public, anon, authenticated;

-- Has the calling device been let go (moved to another device)? Used by the answer rule and the page.
create or replace function public.okflow_is_released()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.okflow_released r where r.labeller = (select auth.uid()))
$$;
revoke all on function public.okflow_is_released() from public, anon, authenticated;
grant execute on function public.okflow_is_released() to authenticated;

alter table public.okflow_answers enable row level security;
revoke all on table public.okflow_answers from public, anon, authenticated;
grant insert on table public.okflow_answers to authenticated;
-- A resent answer is skipped by its id (insert ... on conflict (id) do nothing). Postgres
-- needs SELECT on that column and a select policy for it, so each labeller can see the
-- ids of their own answers, and nothing else.
grant select (id) on table public.okflow_answers to authenticated;

-- The rule on adding answers ("add own answers") is below, after okflow_may_answer: lab sets need a
-- member sign-up, study sets a consent.
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
  code       text primary key,         -- 12 characters, shown as XXXX-XXXX-XXXX (okflow_device_code)
  person     uuid not null,
  set_id     text not null,
  expires_at timestamptz not null
);
alter table public.okflow_codes add column if not exists device uuid;   -- the device that made the code
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

-- The leaderboard: per person, how many cards they answered, under a scrambled handle (never a
-- name: the page shows "You" for the caller and an obviously fake name for everyone else).
-- "me" marks the caller's own row. Dropped first because its columns changed (name -> handle).
drop function if exists public.okflow_board(text);
create function public.okflow_board(p_set text)
returns table (handle text, cards bigint, me boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select substr(md5('okflow:' || coalesce(p.person, a.labeller)::text), 1, 12),
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

-- The first device code (8 characters, okflow_make_code / okflow_use_code) was replaced on 2026-10-29 by
-- okflow_device_code / okflow_link_device, below.
drop function if exists public.okflow_make_code(text);
drop function if exists public.okflow_use_code(text, text);
drop function if exists public.okflow_use_code(text, text, boolean);

-- The calling device's person's latest answer to each card of the set, with their latest name, so linked
-- devices stay in step. Nothing for a device that has been let go.
create or replace function public.okflow_sync(p_set text)
returns table (name text, card text, answer text, decide_ms integer, answered_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  with mine as (
    select a.name, a.card, a.answer, a.decide_ms, a.answered_at, a.seq
    from public.okflow_answers a
    left join public.okflow_people p on p.labeller = a.labeller
    where a.set_id = p_set
      and coalesce(p.person, a.labeller) = public.okflow_person((select auth.uid()))
      and not public.okflow_is_released()
  )
  select (select m.name from mine m order by m.answered_at desc, m.seq desc limit 1),
         x.card, x.answer, x.decide_ms, x.answered_at
  from (select distinct on (m.card) m.card, m.answer, m.decide_ms, m.answered_at, m.seq
        from mine m order by m.card, m.answered_at desc, m.seq desc) x
$$;
revoke all on function public.okflow_sync(text) from public, anon, authenticated;
grant execute on function public.okflow_sync(text) to authenticated;

-- Agreement with others, for the caller only, over the caller's 1,000 most recently answered cards: on each
-- of those that at least two other people answered and where most of them gave the same answer, does the
-- caller's latest answer match theirs? Returns counts only: how many such cards, how many agreed, and how
-- many other people have answered.
create or replace function public.okflow_agreement(p_set text)
returns table (agree bigint, cards bigint, others bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select public.okflow_person((select auth.uid())) as person),
  latest as (
    select distinct on (coalesce(p.person, a.labeller), a.card)
           coalesce(p.person, a.labeller) as person, a.card, a.answer, a.answered_at
    from public.okflow_answers a
    left join public.okflow_people p on p.labeller = a.labeller
    where a.set_id = p_set
    order by coalesce(p.person, a.labeller), a.card, a.answered_at desc, a.seq desc
  ),
  mine as (
    select l.card, l.answer from latest l, me
    where l.person = me.person
    order by l.answered_at desc
    limit 1000
  ),
  votes as (
    select l.card, l.answer, count(*) as n, sum(count(*)) over (partition by l.card) as total
    from latest l, me
    where l.person <> me.person
    group by l.card, l.answer
  ),
  majority as (select v.card, v.answer from votes v where v.total >= 2 and v.n * 2 > v.total)
  select count(*) filter (where m.answer = l.answer),
         count(*),
         (select count(distinct l2.person) from latest l2, me where l2.person <> me.person)
  from mine l
  join majority m on m.card = l.card
$$;
revoke all on function public.okflow_agreement(text) from public, anon, authenticated;
grant execute on function public.okflow_agreement(text) to authenticated;

-- After a move to a new Supabase project, every device signs in afresh and gets a new id. Its first signup
-- carries its id on the old project, whose rows were copied here; that links the new id to the same person,
-- so the person's answers, leaderboard count and device codes carry on. Only a device not linked yet, and
-- only to an id that has answers here. The ids are random and known only to the device that holds them.
create or replace function public.okflow_link_previous()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.previous_labeller is not null and new.previous_labeller <> new.labeller
     and not exists (select 1 from public.okflow_people p where p.labeller = new.labeller)
     and exists (select 1 from public.okflow_answers a where a.labeller = new.previous_labeller) then
    insert into public.okflow_people (labeller, person)
      values (new.labeller, public.okflow_person(new.previous_labeller))
      on conflict (labeller) do nothing;
  end if;
  return new;
end
$$;
revoke all on function public.okflow_link_previous() from public, anon, authenticated;
drop trigger if exists okflow_link_previous on public.okflow_signups;
create trigger okflow_link_previous after insert on public.okflow_signups
  for each row execute function public.okflow_link_previous();

-- Sets and their settings. A set not listed here is a lab set.
create table if not exists public.okflow_sets (
  set_id        text primary key check (length(set_id) between 1 and 40),
  kind          text not null check (kind in ('lab', 'study')),
  study_version text,                                      -- study sets: the protocol version stored on every answer
  info_version  text,                                      -- study sets: the information-and-consent text shown now
  min_people    integer not null default 5 check (min_people >= 1),   -- N: people needed before a cell gets a label
  cap           integer check (cap >= 1),                  -- a cell stops being handed out at this many people (null: no cap)
  practice      integer[] not null default '{}',           -- practice items, left out of consensus
  report        boolean not null default false             -- included in the Student report
);
alter table public.okflow_sets enable row level security;
revoke all on table public.okflow_sets from public, anon, authenticated;
insert into public.okflow_sets (set_id, kind, min_people, practice) values ('okcell_v1', 'lab', 2,
  '{5,9,23,31,39,46,54,75,91,101,104,114,122,123,126,141,142,146,150,178,200,217,223,231,244,246,247,253,263,267,271,282,296,302,310,313,320,327,333,338,339,355,361,363,367,370,386,387,399,416,421,430,434,441,456,465,472,476,481,482,508,512,515,533,535,548,554,558,564,571,586,620,628,635,667,680,687,695,697,699,700,707,714,718,735,736,747,750,766,769,770,775,777,793,798,804,805,838,870,882,899,951,1045,1055,1059,1062,1064,1067,1072,1078,1089,1104,1165,1175,1197,1203,1228,1234,1265,1275}')
  on conflict (set_id) do nothing;

-- What the page needs to know about a set (no sign-in needed).
create or replace function public.okflow_set_info(p_set text)
returns table (kind text, study_version text, info_version text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(s.kind, 'lab'), s.study_version, s.info_version
  from (select 1) one left join public.okflow_sets s on s.set_id = p_set
$$;
revoke all on function public.okflow_set_info(text) from public, anon, authenticated;
grant execute on function public.okflow_set_info(text) to anon, authenticated;

-- Consent: one row per person and information version. Every study answer carries the id of its
-- consent; withdrawing deletes the consent, and with it every answer that carries it.
create table if not exists public.okflow_consents (
  id           uuid primary key default gen_random_uuid(),
  person       uuid not null,
  set_id       text not null references public.okflow_sets (set_id),
  info_version text not null,
  lang         text not null check (lang in ('en', 'fr')),
  adult        boolean not null check (adult),              -- said they are 18 or older
  consented_at timestamptz not null default now()
);
create index if not exists okflow_consents_person on public.okflow_consents (person);
alter table public.okflow_consents enable row level security;
revoke all on table public.okflow_consents from public, anon, authenticated;

alter table public.okflow_answers add column if not exists consent_id uuid;        -- study answers only
alter table public.okflow_answers add column if not exists study_version text;     -- study answers only
create index if not exists okflow_answers_consent on public.okflow_answers (consent_id);
do $$
begin
  if not exists (select from pg_constraint where conname = 'okflow_answers_consent_fk') then
    alter table public.okflow_answers add constraint okflow_answers_consent_fk
      foreign key (consent_id) references public.okflow_consents (id) on delete cascade;
  end if;
  if not exists (select from pg_constraint where conname = 'okflow_answers_study_no_name') then
    alter table public.okflow_answers add constraint okflow_answers_study_no_name
      check (consent_id is null or name = '');               -- study answers carry no name
  end if;
end
$$;

-- May the calling device add this answer? Lab sets: a member sign-up, as before. Study sets: an active
-- consent of the caller's own person, for that set, with the set's current study version.
create or replace function public.okflow_may_answer(p_set text, p_consent uuid, p_version text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s public.okflow_sets;
begin
  select * into s from public.okflow_sets x where x.set_id = p_set;
  if not found or s.kind = 'lab' then
    return p_consent is null and public.okflow_is_member();
  end if;
  return p_version = s.study_version
     and exists (select 1 from public.okflow_consents c
                 where c.id = p_consent and c.set_id = p_set
                   and c.person = public.okflow_person((select auth.uid())));
end
$$;
revoke all on function public.okflow_may_answer(text, uuid, text) from public, anon, authenticated;
grant execute on function public.okflow_may_answer(text, uuid, text) to authenticated;

drop policy if exists "add own answers" on public.okflow_answers;
create policy "add own answers" on public.okflow_answers
  for insert to authenticated
  with check (labeller = (select auth.uid()) and not (select public.okflow_is_released())
              and public.okflow_may_answer(set_id, consent_id, study_version));

-- Deletion codes: 16 characters (Crockford base 32: no I, L, O or U; 80 random bits), one per person.
-- Only a hash is stored; a new code replaces the old one. Typing O for 0 or I/L for 1 still works.
create table if not exists public.okflow_delete_codes (
  person    uuid primary key,
  code_hash text not null unique,
  made_at   timestamptz not null default now()
);
alter table public.okflow_delete_codes enable row level security;
revoke all on table public.okflow_delete_codes from public, anon, authenticated;

create or replace function public.okflow_code_norm(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')), 'OIL', '011')
$$;
revoke all on function public.okflow_code_norm(text) from public, anon, authenticated;

create or replace function public.okflow_code_hash(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to('okflow-delete:' || public.okflow_code_norm(p), 'UTF8')), 'hex')
$$;
revoke all on function public.okflow_code_hash(text) from public, anon, authenticated;

-- n random characters from the code alphabet (256 is a multiple of 32, so every character is equally likely).
create or replace function public.okflow_random_code(n integer)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  abc constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  b bytea := extensions.gen_random_bytes(n);
  c text := '';
begin
  for i in 0 .. n - 1 loop
    c := c || substr(abc, 1 + get_byte(b, i) % 32, 1);
  end loop;
  return c;
end
$$;
revoke all on function public.okflow_random_code(integer) from public, anon, authenticated;

create or replace function public.okflow_issue_code(p_person uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c text := public.okflow_random_code(16);
begin
  insert into public.okflow_delete_codes (person, code_hash) values (p_person, public.okflow_code_hash(c))
    on conflict (person) do update set code_hash = excluded.code_hash, made_at = now();
  return c;
end
$$;
revoke all on function public.okflow_issue_code(uuid) from public, anon, authenticated;

-- Withdrawals: the minimal record kept after a withdrawal (when, which information versions, the
-- person's random id), so a restored backup can have the withdrawal applied again. A withdrawn person
-- can't consent again under the same id: the page starts afresh as someone new.
create table if not exists public.okflow_withdrawals (
  person        uuid primary key,
  info_versions text[] not null,
  withdrawn_at  timestamptz not null default now()
);
alter table public.okflow_withdrawals enable row level security;
revoke all on table public.okflow_withdrawals from public, anon, authenticated;

-- Consent, from the page after the information sheet. Returns the consent id, and the deletion code the
-- first time (null if this person already has one, e.g. a second linked device: it shows "Get a new code").
create or replace function public.okflow_consent(p_set text, p_info_version text, p_lang text, p_adult boolean)
returns table (consent_id uuid, delete_code text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  who uuid;
  s public.okflow_sets;
  cid uuid;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select * into s from public.okflow_sets x where x.set_id = p_set and x.kind = 'study';
  if not found then
    raise exception 'not a study set' using errcode = '22023';
  end if;
  if p_info_version is distinct from s.info_version then
    raise exception 'outdated information sheet' using errcode = '22023';
  end if;
  if p_adult is not true or p_lang is null or p_lang not in ('en', 'fr') then
    raise exception 'consent incomplete' using errcode = '22023';
  end if;
  who := public.okflow_person(me);
  if public.okflow_is_released() or exists (select 1 from public.okflow_withdrawals w where w.person = who) then
    raise exception 'this device has to start afresh' using errcode = '42501';
  end if;
  select c.id into cid from public.okflow_consents c
    where c.person = who and c.set_id = p_set and c.info_version = p_info_version
    order by c.consented_at desc limit 1;
  if cid is null then
    insert into public.okflow_consents (person, set_id, info_version, lang, adult)
      values (who, p_set, p_info_version, p_lang, true)
      returning id into cid;
  end if;
  if exists (select 1 from public.okflow_delete_codes d where d.person = who) then
    return query select cid, null::text;
  else
    return query select cid, public.okflow_issue_code(who);
  end if;
end
$$;
revoke all on function public.okflow_consent(text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.okflow_consent(text, text, text, boolean) to authenticated;

-- The caller's active consent for a study set (null: none, or withdrawn: the page then starts afresh).
create or replace function public.okflow_my_consent(p_set text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.okflow_consents c
  where c.set_id = p_set and c.person = public.okflow_person((select auth.uid()))
  order by c.consented_at desc limit 1
$$;
revoke all on function public.okflow_my_consent(text) from public, anon, authenticated;
grant execute on function public.okflow_my_consent(text) to authenticated;

-- "Get a new code" on a device of a person who has consented: the old code stops working.
create or replace function public.okflow_new_delete_code()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  who uuid := public.okflow_person((select auth.uid()));
begin
  if who is null or not exists (select 1 from public.okflow_consents c where c.person = who) then
    raise exception 'no consent on this device' using errcode = '42501';
  end if;
  return public.okflow_issue_code(who);
end
$$;
revoke all on function public.okflow_new_delete_code() from public, anon, authenticated;
grant execute on function public.okflow_new_delete_code() to authenticated;

-- "Delete my contributions": with a deletion code (from any device, no sign-in needed), or from one of
-- the person's own linked devices without it. Deletes every study answer, consent and the deletion code;
-- device links go too unless the person also labels in a lab set. Lab answers have no consent, so they
-- can't be reached. Returns how many answers were deleted.
create or replace function public.okflow_withdraw(p_code text default null)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  who uuid;
  n integer;
begin
  if length(public.okflow_code_norm(p_code)) > 0 then
    select d.person into who from public.okflow_delete_codes d where d.code_hash = public.okflow_code_hash(p_code);
    if who is null then
      raise exception 'unknown code' using errcode = 'P0002';
    end if;
  else
    if (select auth.uid()) is null then
      raise exception 'not signed in' using errcode = '42501';
    end if;
    who := public.okflow_person((select auth.uid()));
    if not exists (select 1 from public.okflow_consents c where c.person = who) then
      raise exception 'nothing to withdraw' using errcode = 'P0002';
    end if;
  end if;
  select count(*) into n from public.okflow_answers a
    where a.consent_id in (select c.id from public.okflow_consents c where c.person = who);
  insert into public.okflow_withdrawals (person, info_versions)
    select who, coalesce(array_agg(distinct c.set_id || ':' || c.info_version), '{}')
    from public.okflow_consents c where c.person = who
    on conflict (person) do update
      set info_versions = public.okflow_withdrawals.info_versions || excluded.info_versions, withdrawn_at = now();
  delete from public.okflow_consents c where c.person = who;          -- their study answers go with it
  delete from public.okflow_delete_codes d where d.person = who;
  if not exists (select 1 from public.okflow_answers a left join public.okflow_people p on p.labeller = a.labeller
                 where coalesce(p.person, a.labeller) = who) then
    delete from public.okflow_people p where p.person = who;
  end if;
  if to_regprocedure('student.rebuild_report()') is not null then
    execute 'select student.rebuild_report()';
  end if;
  return n;
end
$$;
revoke all on function public.okflow_withdraw(text) from public, anon, authenticated;
grant execute on function public.okflow_withdraw(text) to anon, authenticated;

-- Optional emails, only for the plain-language summary at the end of the study and to ask about
-- acknowledgment. Stored with nothing else: no device, person or time. The page can add or remove an
-- address, never read one.
create table if not exists public.okflow_contacts (
  email text primary key check (length(email) between 3 and 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);
alter table public.okflow_contacts enable row level security;
revoke all on table public.okflow_contacts from public, anon, authenticated;

create or replace function public.okflow_add_contact(p_email text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.okflow_contacts (email) values (lower(trim(p_email))) on conflict (email) do nothing
$$;
revoke all on function public.okflow_add_contact(text) from public, anon, authenticated;
grant execute on function public.okflow_add_contact(text) to anon, authenticated;

create or replace function public.okflow_remove_contact(p_email text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  delete from public.okflow_contacts c where c.email = lower(trim(p_email))
$$;
revoke all on function public.okflow_remove_contact(text) from public, anon, authenticated;
grant execute on function public.okflow_remove_contact(text) to anon, authenticated;

-- People Lucien excluded (labels/swipe/excluded.csv in the analysis repository stays the record; this copy
-- is what the database's consensus and the Student report leave out). An empty window means all answers.
create table if not exists public.okflow_excluded (
  person  uuid not null,
  from_at timestamptz,
  to_at   timestamptz,
  reason  text not null,
  decided text not null,
  unique nulls not distinct (person, from_at, to_at)
);
alter table public.okflow_excluded enable row level security;
revoke all on table public.okflow_excluded from public, anon, authenticated;
insert into public.okflow_excluded (person, reason, decided) values
  ('cd45e125-f713-42a4-b0e4-ef4ffc7ba2c7', 'swiping without looking (41 answers in 2 min on 2026-10-26)', 'Lucien, 2026-10-27')
  on conflict do nothing;

-- Consensus per cell (rules in PROJECT_NOTES.md, "Consensus rules"). Each person's latest answer per card;
-- practice items and excluded answers left out; a person counts on a cell once they answered at least two
-- of its cards (both showings); their score is the sum (keep +1, reject -1, not sure 0) and its sign is
-- their vote. A label needs at least N people, at least half of them leaning, and 75% of those agreeing.
create or replace function public.okflow_consensus(p_set text)
returns table (cell integer, people integer, keep integer, reject integer, label text,
               mean numeric, sd numeric, sums jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  with s as (select * from public.okflow_sets x where x.set_id = p_set),
  latest as (
    select distinct on (coalesce(p.person, a.labeller), a.card)
           coalesce(p.person, a.labeller) as person, a.card, a.answer, a.answered_at
    from public.okflow_answers a
    left join public.okflow_people p on p.labeller = a.labeller
    where a.set_id = p_set
    order by coalesce(p.person, a.labeller), a.card, a.answered_at desc, a.seq desc
  ),
  kept as (
    select l.person, substring(l.card from '^[0-9]+')::integer as cell, l.answer
    from latest l, s
    where not substring(l.card from '^[0-9]+')::integer = any (s.practice)
      and not exists (select 1 from public.okflow_excluded e
                      where e.person = l.person
                        and (e.from_at is null or l.answered_at >= e.from_at)
                        and (e.to_at is null or l.answered_at < e.to_at))
  ),
  counted as (
    select k.person, k.cell, count(*) as showings,
           sum(case k.answer when 'keep' then 1 when 'toss' then -1 else 0 end) as score
    from kept k group by k.person, k.cell
    having count(*) >= 2
  ),
  cells as (
    select c.cell, count(*)::integer as people,
           (count(*) filter (where c.score > 0))::integer as keep,
           (count(*) filter (where c.score < 0))::integer as reject,
           avg(c.score::numeric / c.showings) as mean,
           stddev_samp(c.score::numeric / c.showings) as sd
    from counted c group by c.cell
  ),
  dist as (
    select d.cell, jsonb_object_agg(d.score::text, d.n order by d.score) as sums
    from (select c.cell, c.score, count(*) as n from counted c group by c.cell, c.score) d
    group by d.cell
  )
  select c.cell, c.people, c.keep, c.reject,
         case when c.people >= s.min_people and (c.keep + c.reject) * 2 >= c.people
                   and greatest(c.keep, c.reject) >= 0.75 * (c.keep + c.reject)
              then case when c.keep > c.reject then 'keep' else 'reject' end
              else 'unresolved' end,
         c.mean, c.sd, d.sums
  from cells c join dist d on d.cell = c.cell, s
$$;
revoke all on function public.okflow_consensus(text) from public, anon, authenticated;

-- For handing out cells closest to ready: per cell, how many people count so far and whether it is done
-- (labelled, or at the cap). Counts only, nothing about anyone.
create or replace function public.okflow_progress(p_set text)
returns table (cell integer, people integer, done boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select x.cell, x.people, x.label <> 'unresolved' or x.people >= coalesce(s.cap, 2147483647)
  from public.okflow_consensus(p_set) x, public.okflow_sets s
  where s.set_id = p_set
$$;
revoke all on function public.okflow_progress(text) from public, anon, authenticated;
grant execute on function public.okflow_progress(text) to authenticated;

-- The Student report (Elham): per cell, rebuilt nightly and after every withdrawal, for the sets marked
-- report. Below 5 people: "fewer than 5", the label and the mean only.
create schema if not exists student;
revoke all on schema student from public;
create table if not exists student.report (
  set_id      text not null,
  cell        integer not null,
  people      text not null,          -- how many people count on the cell, or 'fewer than 5'
  label       text not null check (label in ('keep', 'reject', 'unresolved')),
  mean_answer numeric(4, 3),          -- mean over people of their average answer (keep +1, reject -1, not sure 0)
  sd_answer   numeric(4, 3),          -- spread of those averages; empty below 5 people
  sums        jsonb,                  -- how many people had each summed score, e.g. {"-2": 1, "2": 4}; empty below 5
  built_on    date not null,
  primary key (set_id, cell)
);
alter table student.report enable row level security;
revoke all on table student.report from public, anon, authenticated;

create or replace function student.rebuild_report()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  delete from student.report r where true;
  insert into student.report (set_id, cell, people, label, mean_answer, sd_answer, sums, built_on)
    select s.set_id, x.cell,
           case when x.people < 5 then 'fewer than 5' else x.people::text end,
           x.label, round(x.mean, 3),
           case when x.people < 5 then null else round(x.sd, 3) end,
           case when x.people < 5 then null else x.sums end,
           current_date
    from public.okflow_sets s, lateral public.okflow_consensus(s.set_id) x
    where s.report;
end
$$;
revoke all on function student.rebuild_report() from public, anon, authenticated;

-- Elham's login: reads the Student report and nothing else. Made without a password; give it one in a
-- separate query typed in the SQL Editor (never saved): alter role okflow_student with password '...';
do $$
begin
  if not exists (select from pg_roles where rolname = 'okflow_student') then
    create role okflow_student with login;
  end if;
end
$$;
alter role okflow_student set default_transaction_read_only = on;
grant usage on schema student to okflow_student;
grant select on table student.report to okflow_student;
drop policy if exists "student reads the report" on student.report;
create policy "student reads the report" on student.report for select to okflow_student using (true);

-- The device code: 12 characters (60 random bits), single use, 15 minutes, at most 5 wrong tries per
-- device in 15 minutes, and it returns only 'linked' (the answers then come through okflow_sync).
create table if not exists public.okflow_code_tries (
  labeller uuid not null,
  tried_at timestamptz not null default now()
);
create index if not exists okflow_code_tries_labeller on public.okflow_code_tries (labeller, tried_at);
alter table public.okflow_code_tries enable row level security;
revoke all on table public.okflow_code_tries from public, anon, authenticated;

create or replace function public.okflow_device_code(p_set text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  who uuid := public.okflow_person((select auth.uid()));
  c text := public.okflow_random_code(12);
begin
  if who is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  delete from public.okflow_codes k where k.expires_at < now() or k.person = who;
  insert into public.okflow_codes (code, person, set_id, expires_at, device)
    values (c, who, p_set, now() + interval '15 minutes', (select auth.uid()));
  return c;
end
$$;
revoke all on function public.okflow_device_code(text) from public, anon, authenticated;
grant execute on function public.okflow_device_code(text) to authenticated;

create or replace function public.okflow_link_device(p_code text, p_set text, p_move boolean default false)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  who uuid;
  maker uuid;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  delete from public.okflow_code_tries t where t.tried_at < now() - interval '1 hour';
  if (select count(*) from public.okflow_code_tries t
      where t.labeller = me and t.tried_at > now() - interval '15 minutes') >= 5 then
    return 'wait';
  end if;
  delete from public.okflow_codes k
    where k.code = public.okflow_code_norm(p_code) and k.set_id = p_set and k.expires_at >= now()
    returning k.person, k.device into who, maker;
  if who is null then
    insert into public.okflow_code_tries (labeller) values (me);
    return 'unknown';
  end if;
  if who <> public.okflow_person(me) then
    update public.okflow_people set person = who, linked_at = now() where person = me;
    insert into public.okflow_people (labeller, person) values (me, who)
      on conflict (labeller) do update set person = excluded.person, linked_at = now();
  end if;
  if p_move and maker is not null and maker <> me then
    insert into public.okflow_released (labeller, by_device) values (maker, me) on conflict (labeller) do nothing;
  end if;
  return 'linked';
end
$$;
revoke all on function public.okflow_link_device(text, text, boolean) from public, anon, authenticated;
grant execute on function public.okflow_link_device(text, text, boolean) to authenticated;

-- The Student report is rebuilt every night at 07:15 UTC (pg_cron; scheduling the same name again replaces it).
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('okflow-student-report', '15 7 * * *', 'select student.rebuild_report()');

-- The test study set behind okflow.weisslab.ca/?study (study.json). Its versions must match study.json:
-- consent to any other information version and answers under any other study version are refused. Not in
-- the Student report. The real study gets its own set once the ethics committee approves the text.
insert into public.okflow_sets (set_id, kind, study_version, info_version, min_people, practice, report)
  select 'okflow_study_test', 'study', 'test-2026-10-29', 'draft-2026-10-29', 5, s.practice, false
  from public.okflow_sets s where s.set_id = 'okcell_v1'
  on conflict (set_id) do update
    set kind = excluded.kind, study_version = excluded.study_version, info_version = excluded.info_version;

-- What people type is cleaned and checked before it is stored. The page sends values as parameters and no
-- function builds SQL from text, so SQL injection isn't possible; this guards what ends up in the tables and
-- in the CSV files opened in Excel.

-- A name: no control or direction-changing characters, none of < > " ` \, and no leading = + - @ (Excel reads
-- those as a formula), trimmed, at most 60 characters. The page cleans names the same way.
create or replace function public.okflow_clean_name(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(regexp_replace(btrim(regexp_replace(translate(coalesce(p, ''), '<>"`' || chr(92), ''),
              '[[:cntrl:]\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]', '', 'g')),
              '^[-=+@[:space:]]+', ''), 60)
$$;

-- Every answer: the name cleaned, a phone clock more than a day ahead replaced by the server's time, and at
-- most 20,000 answers per device and set (a deck is a few thousand cards). A refusal uses a check-violation
-- code, so the page keeps the answers on the device instead of retrying forever.
create or replace function public.okflow_answers_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.name := public.okflow_clean_name(new.name);
  if new.answered_at > now() + interval '1 day' then
    new.answered_at := now();
  end if;
  if (select count(*) from public.okflow_answers a where a.set_id = new.set_id and a.labeller = new.labeller) >= 20000 then
    raise exception 'too many answers from this device' using errcode = '23514';
  end if;
  return new;
end
$$;
revoke all on function public.okflow_answers_check() from public, anon, authenticated;
drop trigger if exists okflow_answers_check on public.okflow_answers;
create trigger okflow_answers_check before insert on public.okflow_answers
  for each row execute function public.okflow_answers_check();

do $$
begin
  if not exists (select from pg_constraint where conname = 'okflow_answers_set_id_safe') then
    alter table public.okflow_answers add constraint okflow_answers_set_id_safe
      check (set_id ~ '^[a-z0-9_]{1,40}$');
  end if;
end
$$;

-- Email addresses (sign-ups and the optional summary email): plain letters, digits and . _ % + ' - before the
-- @, starting with a letter or digit; a domain of letters, digits and hyphens. Checked on new rows only
-- (not valid): existing sign-ups stay as they are.
do $$
begin
  if not exists (select from pg_constraint where conname = 'okflow_signups_email_safe') then
    alter table public.okflow_signups add constraint okflow_signups_email_safe
      check (email ~ '^[A-Za-z0-9][A-Za-z0-9._%+''-]*@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$') not valid;
  end if;
  if not exists (select from pg_constraint where conname = 'okflow_contacts_email_safe') then
    alter table public.okflow_contacts add constraint okflow_contacts_email_safe
      check (email ~ '^[A-Za-z0-9][A-Za-z0-9._%+''-]*@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$') not valid;
  end if;
end
$$;

-- Sign-ups: the email trimmed, at most 5 rows per device (a row is added only when the member answer or the email changes).
create or replace function public.okflow_signups_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.email := btrim(new.email);
  if (select count(*) from public.okflow_signups s where s.labeller = new.labeller) >= 5 then
    raise exception 'too many sign-ups from this device' using errcode = '23514';
  end if;
  return new;
end
$$;
revoke all on function public.okflow_signups_check() from public, anon, authenticated;
drop trigger if exists okflow_signups_check on public.okflow_signups;
create trigger okflow_signups_check before insert on public.okflow_signups
  for each row execute function public.okflow_signups_check();

-- The optional summary email: anyone can add one without signing in, so the list stops at 10,000 addresses.
create or replace function public.okflow_add_contact(p_email text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.okflow_contacts) >= 10000 then
    raise exception 'the contact list is full' using errcode = '23514';
  end if;
  insert into public.okflow_contacts (email) values (lower(btrim(p_email))) on conflict (email) do nothing;
end
$$;
revoke all on function public.okflow_add_contact(text) from public, anon, authenticated;
grant execute on function public.okflow_add_contact(text) to anon, authenticated;

select student.rebuild_report();
