# LexCockpit ingest pipeline (Node)

Node.js worker that mirrors the Supabase Edge Function
`supabase/functions/ingest-news`.

**Default is free:** RSS → keyword score → waiting list (`review_queue`).

## Setup

```bash
cd pipeline
cp .env.example .env   # SUPABASE_URL + SERVICE_ROLE_KEY is enough for scan_only
npm install
```

Apply both SQL migrations in `../supabase/migrations/` first (see
`../supabase/SCAN_ONLY_SETUP.md`).

## Commands

| Command | What it does |
|---------|----------------|
| `npm run ingest` | **Free** scan-only → `queued` waiting list |
| `npm run ingest:full` | Paid LLM drafts (needs API keys) |
| `npm run ingest:dry` | Fetch + dedup only |
| `npm run trigger` | POST the deployed Edge Function |
| `npm run test` | Unit + RSS smoke tests |
| `node src/run.mjs --source politico-europe` | Limit to one seeded source |

## Cron example

```cron
0 */2 * * * cd /path/to/lexcockpit/pipeline && /usr/bin/npm run ingest >> /var/log/lex-ingest.log 2>&1
```

Or trigger the Edge Function:

```cron
0 */2 * * * cd /path/to/lexcockpit/pipeline && /usr/bin/npm run trigger
```
