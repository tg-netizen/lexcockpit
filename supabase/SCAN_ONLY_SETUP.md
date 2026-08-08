# Free scan-only setup (waiting list)

Default pipeline mode: **scan RSS → keyword filter → `review_queue`**.  
No OpenAI/Anthropic keys. No auto-writing.

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

grant select on public.review_queue to authenticated;
```

(If you never ran the first migration, run both SQL files under `migrations/` in order.)

## 2. Secrets for free mode

Only needed to *invoke* the function securely (optional for local Node worker):

- `CRON_SECRET` — random string
- (Supabase auto-provides `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`)

Set `PIPELINE_MODE=scan_only` (this is already the default).

**Do not set** `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` until you want paid drafts.

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
