# Free scan-only setup (waiting list)

Default pipeline mode: **scan RSS → keyword filter → `review_queue`**.  
No OpenAI/Anthropic keys. No auto-writing.

`full` mode (LLM drafts) requires `PIPELINE_MODE=full` **and** an
`OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in the function's secrets. Without a
key the function stays in `scan_only` — including when `?mode=full` is passed
on the URL. Nothing can switch on paid mode from the outside.

The function has `verify_jwt = false` (so pg_cron and CI can call it with a
plain header), which makes `CRON_SECRET` the only thing standing in front of
it. Set it. Without both `CRON_SECRET` and a service-role key the function
refuses every request rather than running open.

## 1. Run this SQL (if you already ran the first migration)

Open https://supabase.com/dashboard/project/fstoenrocfyzdsgmiknj/sql/new and run:

```sql
alter table public.ingested_items
  drop constraint if exists ingested_items_status_check;

alter table public.ingested_items
  add constraint ingested_items_status_check
  check (status in (
    'fetched', 'evaluated', 'queued', 'rejected', 'drafted', 'error', 'duplicate'
  ));

create or replace view public.review_queue
with (security_invoker = true)
as
select
  i.id,
  i.title,
  i.source_url,
  i.snippet,
  i.published_at,
  i.relevance_score,
  i.relevance_reason,
  i.status,
  i.created_at,
  s.name as source_name,
  s.slug as source_slug,
  s.region
from public.ingested_items i
left join public.news_sources s on s.id = i.source_id
where i.status = 'queued'
order by i.relevance_score desc nulls last, i.created_at desc;

grant select on public.review_queue to anon, authenticated;

-- RLS: view is security_invoker, so anon needs SELECT on base tables too
drop policy if exists "Anon read queued ingested_items" on public.ingested_items;
create policy "Anon read queued ingested_items"
  on public.ingested_items for select
  to anon
  using (status = 'queued');

drop policy if exists "Anon read news_sources" on public.news_sources;
create policy "Anon read news_sources"
  on public.news_sources for select
  to anon
  using (true);
```

(If you never ran the first migration, run the SQL files under `migrations/` in order.)

## 2. Secrets for free mode

Only needed to *invoke* the function securely (optional for local Node worker):

- `CRON_SECRET` — random string
- `PIPELINE_MODE=scan_only` (default)
- (Supabase auto-provides `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`)

**Do not set** `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` until you want paid drafts.

### LexCockpit Mac app

Settings → **Ingest**:
- Project URL: `https://fstoenrocfyzdsgmiknj.supabase.co`
- **anon / publishable** key (Project Settings → API) — never `service_role`
- **Test waiting list** → should say `✓ review_queue reachable`

Overview then shows **News waiting list**.

## 3. Deploy function + pull via GitHub Desktop

1. In GitHub Desktop: fetch the branch `cursor/content-ingestion-pipeline-1e36` (or merge PR #1 into `main`)
2. Deploy Edge Function `ingest-news` (Supabase GitHub integration, or CLI)
3. Trigger once:

```bash
curl -X POST "https://fstoenrocfyzdsgmiknj.supabase.co/functions/v1/ingest-news" \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY" \
  -H "x-cron-secret: YOUR_CRON_SECRET" \
  -H "Content-Type: application/json"
```

Or locally:

```bash
cd pipeline
cp .env.example .env   # add service_role key
npm install
npm run ingest
```

## 4. See the waiting list

SQL Editor:

```sql
select * from review_queue;
```

Or Table Editor → `ingested_items` → filter `status = queued`.

## 5. Hardening + feed repair (run once)

Run `supabase/migrations/20260808170000_tighten_grants_and_fix_feeds.sql` in the
SQL editor. It narrows anon to the ten columns `review_queue` actually exposes
(it could previously read every column of queued rows, including the full RSS
payload in `raw`), drops the blanket "any authenticated user may update any
article" policy, and replaces the three seeded feeds that were dead on
2026-08-08 — Euractiv (403), EU Sanctions Map (404) and NATO (HTML, no items) —
with six that were fetched and confirmed to parse.
