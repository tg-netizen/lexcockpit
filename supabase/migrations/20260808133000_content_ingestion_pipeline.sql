-- Content ingestion & AI draft pipeline for LexCockpit / LexDigestGlobal.
-- Stages RSS items, relevance scores, and structured article drafts.
-- LexCockpit itself still reads/writes Markdown via GitHub; this schema is
-- the server-side system of record for automated ingestion. The Edge Function
-- optionally mirrors accepted drafts into the content repo as Markdown with
-- `ai_generated: true` so they appear in the Cockpit Content / Overview tabs.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Configurable news sources (RSS)
-- ---------------------------------------------------------------------------
create table if not exists public.news_sources (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  feed_url text not null,
  homepage_url text,
  region text,
  language text default 'en',
  enabled boolean not null default true,
  max_items_per_run integer not null default 15,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists news_sources_enabled_idx
  on public.news_sources (enabled) where enabled = true;

-- ---------------------------------------------------------------------------
-- Dedup log: every fetched item, whether kept or discarded
-- ---------------------------------------------------------------------------
create table if not exists public.ingested_items (
  id uuid primary key default gen_random_uuid(),
  source_id uuid references public.news_sources (id) on delete set null,
  source_url text not null,
  title text not null,
  snippet text,
  published_at timestamptz,
  relevance_score numeric(4,3),
  relevance_reason text,
  is_relevant boolean,
  status text not null default 'fetched'
    check (status in (
      'fetched', 'evaluated', 'rejected', 'drafted', 'error', 'duplicate'
    )),
  article_id uuid,
  error_message text,
  raw jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ingested_items_source_url_unique unique (source_url)
);

create index if not exists ingested_items_status_idx on public.ingested_items (status);
create index if not exists ingested_items_created_at_idx on public.ingested_items (created_at desc);

-- ---------------------------------------------------------------------------
-- Articles: structured AI briefings / human drafts
-- Mirrors the editorial statuses LexCockpit already understands, plus `concept`.
-- ---------------------------------------------------------------------------
create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  working_title text not null,
  slug text not null,
  status text not null default 'concept'
    check (status in ('concept', 'draft', 'scheduled', 'published', 'archived')),
  origin text not null default 'manual'
    check (origin in ('manual', 'ai-ingest')),
  ai_generated boolean not null default false,
  review_required boolean not null default false,
  core_fact_summary text,
  strategic_impact text,
  outline jsonb not null default '[]'::jsonb,
  body_markdown text,
  source_url text,
  source_name text,
  source_published_at timestamptz,
  source_metadata jsonb not null default '{}'::jsonb,
  relevance_score numeric(4,3),
  relevance_criteria text[] not null default '{}',
  topic text,
  tags text[] not null default '{}',
  github_path text,
  github_commit_sha text,
  ingested_item_id uuid references public.ingested_items (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint articles_slug_unique unique (slug)
);

create index if not exists articles_status_idx on public.articles (status);
create index if not exists articles_ai_review_idx
  on public.articles (ai_generated, review_required)
  where ai_generated = true;
create index if not exists articles_source_url_idx on public.articles (source_url);

alter table public.ingested_items
  drop constraint if exists ingested_items_article_id_fkey;
alter table public.ingested_items
  add constraint ingested_items_article_id_fkey
  foreign key (article_id) references public.articles (id) on delete set null;

-- ---------------------------------------------------------------------------
-- Pipeline run telemetry
-- ---------------------------------------------------------------------------
create table if not exists public.pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running'
    check (status in ('running', 'ok', 'partial', 'error')),
  sources_scanned integer not null default 0,
  items_fetched integer not null default 0,
  items_new integer not null default 0,
  items_relevant integer not null default 0,
  drafts_created integer not null default 0,
  error_message text,
  details jsonb not null default '{}'::jsonb
);

-- ---------------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists news_sources_set_updated_at on public.news_sources;
create trigger news_sources_set_updated_at
  before update on public.news_sources
  for each row execute function public.set_updated_at();

drop trigger if exists ingested_items_set_updated_at on public.ingested_items;
create trigger ingested_items_set_updated_at
  before update on public.ingested_items
  for each row execute function public.set_updated_at();

drop trigger if exists articles_set_updated_at on public.articles;
create trigger articles_set_updated_at
  before update on public.articles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS — cockpit users read; writes go through service role / Edge Function
-- ---------------------------------------------------------------------------
alter table public.news_sources enable row level security;
alter table public.ingested_items enable row level security;
alter table public.articles enable row level security;
alter table public.pipeline_runs enable row level security;

drop policy if exists "Authenticated read news_sources" on public.news_sources;
create policy "Authenticated read news_sources"
  on public.news_sources for select
  to authenticated
  using (true);

drop policy if exists "Authenticated read ingested_items" on public.ingested_items;
create policy "Authenticated read ingested_items"
  on public.ingested_items for select
  to authenticated
  using (true);

drop policy if exists "Authenticated read articles" on public.articles;
create policy "Authenticated read articles"
  on public.articles for select
  to authenticated
  using (true);

drop policy if exists "Authenticated update articles" on public.articles;
create policy "Authenticated update articles"
  on public.articles for update
  to authenticated
  using (true)
  with check (true);

drop policy if exists "Authenticated read pipeline_runs" on public.pipeline_runs;
create policy "Authenticated read pipeline_runs"
  on public.pipeline_runs for select
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Seed LexDigestGlobal-relevant sources
-- ---------------------------------------------------------------------------
insert into public.news_sources (name, slug, feed_url, homepage_url, region, language) values
  ('Times of Israel', 'times-of-israel',
   'https://www.timesofisrael.com/feed/',
   'https://www.timesofisrael.com/', 'IL', 'en'),
  ('Defence News', 'defence-news',
   'https://www.defensenews.com/arc/outboundfeeds/rss/?outputType=xml',
   'https://www.defensenews.com/', 'US', 'en'),
  ('Politico Europe', 'politico-europe',
   'https://www.politico.eu/feed/',
   'https://www.politico.eu/', 'EU', 'en'),
  ('Euractiv', 'euractiv',
   'https://www.euractiv.com/feed/',
   'https://www.euractiv.com/', 'EU', 'en'),
  ('Tagesschau (ARD)', 'ard-tagesschau',
   'https://www.tagesschau.de/index~rss2.xml',
   'https://www.tagesschau.de/', 'DE', 'de'),
  ('ABC News World', 'abc-news-world',
   'https://abcnews.go.com/abcnews/internationalheadlines',
   'https://abcnews.go.com/', 'US', 'en'),
  ('EU Sanctions Map News', 'eu-sanctions',
   'https://www.sanctionsmap.eu/api/v1/news/rss',
   'https://www.sanctionsmap.eu/', 'EU', 'en'),
  ('NATO News', 'nato-news',
   'https://www.nato.int/cps/en/natohq/news.htm?theme=all&display_mode=rss',
   'https://www.nato.int/', 'NATO', 'en')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- Optional cron schedule (enable pg_cron + pg_net in the dashboard first).
-- Secrets should live in Vault — see supabase/README.md.
-- ---------------------------------------------------------------------------
-- select cron.schedule(
--   'lexcockpit-ingest-news',
--   '0 */2 * * *',
--   $$
--   select net.http_post(
--     url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
--            || '/functions/v1/ingest-news',
--     headers := jsonb_build_object(
--       'Content-Type', 'application/json',
--       'Authorization', 'Bearer ' ||
--         (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
--       'x-cron-secret',
--         (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
--     ),
--     body := '{"trigger":"pg_cron"}'::jsonb
--   );
--   $$
-- );
