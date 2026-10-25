# OKFlow

A swipe page for sorting imaging flow cytometry cell images: right keeps a cell
(sharp, whole, single), left tosses it (blurry, streaked, cut off, two cells, a
bead or debris), up is "not sure". It builds a reference set of human labels
for the Weiss Lab's work on removing poor-quality images from imaging flow
cytometry data.

Live at **https://okflow.weisslab.ca** (and https://weisslab.ca/okflow, which redirects there).

## What's here

| File | What |
|---|---|
| `index.html` | The whole page: name, examples, labelling, milestones every 50 cards, leaderboard |
| `config.js` | The Supabase project URL and publishable key |
| `cards.json` | The label set's id and the card order. A card is the cell number, its flip (`h` left-right, `v` upside down, `hv` both) and `b` when it shows brightfield only |
| `sheets/` | The cell images, lossless PNG: `sheet_NN.png` holds cells 100·NN+1 to 100·NN+100, five per row, each 80 px brightfield + 2 px gap + 80 px fluorescence; `guide.png` holds the nine examples |
| `setup.sql` | The Supabase tables, their rules, the leaderboard and the device codes. Safe to rerun after an update |
| `CNAME` | The custom domain for GitHub Pages |

Nothing here says which run, condition or time point a cell came from. The
images and card order are made in the (private) analysis repository by
`scripts/make_swipe_set.py`.

## How answers are stored

Every swipe adds one row to the Supabase table `okflow_answers`: the label set,
an anonymous labeller id, the name they typed, the card, the answer, the time to
decide, a per-labeller sequence number, and the phone's and the server's clocks.
Changing an answer adds a newer row for the same card; nothing is overwritten.
Each browser signs in anonymously, and the page keeps the person's place and
any unsent answers on that device, sending them when it's back online.

Through the public key, the page can only add rows under its own anonymous id
and read the leaderboard (names and counts). It can't read, change or delete
answers.

**Switching device:** "switch device" on the labelling screen shows a one-time
code (15 minutes). Entering it under the name box on another device links that
device to the same person (table `okflow_people`) and brings over the person's
name and latest answers, so they continue where they were. Both devices then
count as one person on the leaderboard and in the analysis.

## Set up (once)

Done 2026-10-25: Supabase organization WeissLab, project OKFlow (`mflrlsqsawvuyhfxzajc`);
DNS record `okflow` in Cloudflare (proxied). The steps are kept for rebuilding it.

### 1. Supabase

1. At supabase.com, create a project (any name, e.g. `okflow`; free plan; a region near Montréal, e.g. Canada Central).
2. **SQL Editor** → New query → paste all of `setup.sql` → **Run**. It should say "Success. No rows returned".
3. **Authentication** → **Sign In / Providers** → turn on **Allow anonymous sign-ins** → Save.
4. **Project Settings** → **API Keys**: copy the **publishable** key. **Project Settings** → **Data API** (or the Connect button): copy the **Project URL**.
5. Put both in `config.js` and commit. Never put the **secret** (service_role) key anywhere in this repo.

Free projects pause after a week without use; restore one from the Supabase dashboard. Answers are kept.

### 2. Domain (Cloudflare, where weisslab.ca's DNS is)

1. dash.cloudflare.com → weisslab.ca → **DNS** → **Records** → **Add record**: Type `CNAME`, Name `okflow`, Target `weisslab.github.io`, Proxy status **DNS only** (grey cloud) → Save.
2. **Rules** → **Redirect Rules** → Create rule: When incoming requests match *Custom filter expression*, Hostname equals `weisslab.ca` **and** URI Path starts with `/okflow`. Then *Static*, URL `https://okflow.weisslab.ca`, status 302 → Deploy. (Add `www.weisslab.ca` with "or" if the site is also served there.)
3. In GitHub, this repo's **Settings** → **Pages**: once the DNS check passes, tick **Enforce HTTPS**.

## Get the answers

Supabase → **Table Editor** → `okflow_answers` and `okflow_people` → **Export** →
**Export to CSV** (each), then in the analysis repository:

    uv run python scripts/import_swipe_labels.py okflow_answers_rows.csv --people okflow_people_rows.csv

## Change the cells

Make a new label set in the analysis repository; copy its `sheets/` and
`cards.json` here. The set id in `cards.json` keeps answers to different sets
apart, and each set keeps its own progress on each device.
