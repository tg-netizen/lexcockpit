-- Hardening pass over the ingestion schema, plus a repair of the seeded feeds.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. anon sees the waiting list, and nothing beyond it
-- ---------------------------------------------------------------------------
-- The earlier migration revoked insert/update/delete from anon but never
-- touched select, and Supabase's default privileges grant ALL on new tables in
-- `public` to anon. RLS was doing all the work on its own: the policy limits
-- anon to rows with status = 'queued', but says nothing about COLUMNS. So
-- /rest/v1/ingested_items?status=eq.queued returned every column of those rows,
-- including `raw` (the entire RSS payload) and `error_message` — well beyond
-- the twelve columns review_queue was built to expose.
--
-- Column grants are the fix rather than a blanket revoke: review_queue is
-- security_invoker, so it runs with the CALLER's privileges and would break if
-- anon lost select on the base table altogether.
revoke select on public.ingested_items from anon;
grant select (
  id, source_id, title, source_url, snippet, published_at,
  relevance_score, relevance_reason, status, created_at
) on public.ingested_items to anon;

-- Same treatment for the join side: anon needs three columns, not the row.
revoke select on public.news_sources from anon;
grant select (id, name, slug, region) on public.news_sources to anon;

-- Belt and braces: if RLS is ever switched off in the dashboard, these two
-- should still be unreachable for anon rather than instantly world-readable.
revoke all on public.articles from anon;
revoke all on public.pipeline_runs from anon;

-- ---------------------------------------------------------------------------
-- 2. No blanket write path for every signed-in user
-- ---------------------------------------------------------------------------
-- "Authenticated update articles ... using (true) with check (true)" let any
-- authenticated user rewrite any article row, including flipping status to
-- 'published'. Nothing in LexCockpit uses it: the app talks to PostgREST with
-- the anon key only and never signs a user in, and the pipeline writes with the
-- service role, which bypasses RLS anyway. So this policy protected nothing and
-- would have mattered the moment public sign-up was switched on.
--
-- Re-add a scoped version here if an authenticated editor UI is ever built.
drop policy if exists "Authenticated update articles" on public.articles;

-- ---------------------------------------------------------------------------
-- 3. Repair the seeded sources
-- ---------------------------------------------------------------------------
-- Three of the eight seeded feeds were dead when checked on 2026-08-08:
--   Euractiv               → HTTP 403 (Cloudflare blocks non-browser clients)
--   EU Sanctions Map News  → HTTP 404 (the endpoint does not exist)
--   NATO News              → HTTP 200 but serves HTML, zero RSS items
-- Losing the sanctions and NATO feeds meant the two most on-topic sources in
-- the list were the ones contributing nothing. Every replacement below was
-- fetched and confirmed to return parseable items before being written here.
update public.news_sources set enabled = false
 where slug in ('euractiv', 'eu-sanctions', 'nato-news');

insert into public.news_sources (name, slug, feed_url, homepage_url, region, language) values
  -- EU regulation, straight from the source: 30 items, the Commission's own wire.
  ('European Commission press', 'ec-press',
   'https://ec.europa.eu/commission/presscorner/api/rss?language=en&pagesize=30',
   'https://ec.europa.eu/commission/presscorner/', 'EU', 'en'),
  -- Replaces the dead sanctions map: a dedicated EU/UK sanctions practice feed.
  ('European Sanctions', 'european-sanctions',
   'https://www.europeansanctions.com/feed/',
   'https://www.europeansanctions.com/', 'EU', 'en'),
  -- Replaces NATO's broken feed for the defence-industrial beat.
  ('Breaking Defense', 'breaking-defense',
   'https://breakingdefense.com/feed/',
   'https://breakingdefense.com/', 'US', 'en'),
  ('Defense One', 'defense-one',
   'https://www.defenseone.com/rss/all/',
   'https://www.defenseone.com/', 'US', 'en'),
  -- Euractiv's German edition answers where the English one returns 403.
  ('Euractiv Deutschland', 'euractiv-de',
   'https://www.euractiv.de/feed/',
   'https://www.euractiv.de/', 'DE', 'de'),
  ('Bundesregierung', 'bundesregierung',
   'https://www.bundesregierung.de/service/rss/breg-de/1151244/feed.xml',
   'https://www.bundesregierung.de/', 'DE', 'de')
on conflict (slug) do update
  set feed_url = excluded.feed_url,
      homepage_url = excluded.homepage_url,
      enabled = true;

-- ---------------------------------------------------------------------------
-- 4. A source_url long enough to break its own index cannot be inserted
-- ---------------------------------------------------------------------------
-- `ingested_items_source_url_unique` is a btree index on unbounded text. A
-- btree entry cannot exceed roughly 2704 bytes, so a single hostile or broken
-- feed item with an absurdly long link would fail the insert and take the rest
-- of that source's batch down with it. Rejecting the value with a readable
-- constraint beats an index-internal error nobody can act on.
alter table public.ingested_items
  drop constraint if exists ingested_items_source_url_len;
alter table public.ingested_items
  add constraint ingested_items_source_url_len
  check (octet_length(source_url) <= 2000);
