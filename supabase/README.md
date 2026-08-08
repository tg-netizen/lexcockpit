# LexCockpit — automated content ingestion

Server-side pipeline that scans configured RSS sources, filters for LexDigestGlobal
relevance (EU Regulation, Sanctions, Defence Supply Chains, Geopolitics), and
writes structured AI drafts into Supabase `articles` **and** (optionally) the
GitHub Markdown content repo so they show up in LexCockpit’s **Content / Overview**
tabs with an **AI Draft / Review Required** badge.

> LexCockpit itself remains a SwiftUI macOS app that reads articles from GitHub.
> This Supabase project is the ingestion + staging database the prompt asked for.

## Tables

| Table | Role |
|-------|------|
| `news_sources` | Configurable RSS feeds |
| `ingested_items` | Dedup log + relevance verdicts (`source_url` unique) |
| `articles` | Structured drafts (`status`: concept / draft / …, `ai_generated`, `review_required`) |
| `pipeline_runs` | Per-run telemetry |

## Deploy

**Live project:** `https://fstoenrocfyzdsgmiknj.supabase.co`  
**Project ref:** `fstoenrocfyzdsgmiknj`  
**Dashboard:** https://supabase.com/dashboard/project/fstoenrocfyzdsgmiknj

```bash
# 1. Link + push schema + deploy function
npm i -g supabase
supabase login
supabase link --project-ref fstoenrocfyzdsgmiknj
supabase db push
supabase functions deploy ingest-news

# 2. Secrets
supabase secrets set \
  CRON_SECRET=... \
  OPENAI_API_KEY=... \          # or ANTHROPIC_API_KEY=...
  LLM_PROVIDER=openai \         # openai | anthropic
  GITHUB_PAT=ghp_... \
  GITHUB_REPO=tg-netizen/lexdigestglobal-real-version \
  GITHUB_BRANCH=main \
  GITHUB_CONTENT_PATH=content/articles/
```

Dashboard shortcut (no CLI): open
[SQL Editor](https://supabase.com/dashboard/project/fstoenrocfyzdsgmiknj/sql/new)
and paste `migrations/20260808133000_content_ingestion_pipeline.sql`.

## Invoke

```bash
curl -X POST "https://fstoenrocfyzdsgmiknj.supabase.co/functions/v1/ingest-news" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "x-cron-secret: $CRON_SECRET" \
  -H "Content-Type: application/json"
```

Dry run (fetch + dedup only, no LLM / no drafts):

```bash
curl -X POST "https://fstoenrocfyzdsgmiknj.supabase.co/functions/v1/ingest-news?dry_run=1" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "x-cron-secret: $CRON_SECRET"
```

## Schedule (pg_cron + pg_net)

Store secrets in Vault, then uncomment the `cron.schedule` block at the bottom of
`migrations/20260808133000_content_ingestion_pipeline.sql`, or run:

```sql
select cron.schedule(
  'lexcockpit-ingest-news',
  '0 */2 * * *',  -- every 2 hours
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/ingest-news',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' ||
        (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'x-cron-secret',
        (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{"trigger":"pg_cron"}'::jsonb
  );
  $$
);
```

## Local Node worker

See [`../pipeline/`](../pipeline/) for a Node.js worker that can either call the
Edge Function or run the same steps with the service role key.
