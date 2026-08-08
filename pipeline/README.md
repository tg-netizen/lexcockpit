# LexCockpit ingest pipeline (Node)

Node.js worker that mirrors the Supabase Edge Function
`supabase/functions/ingest-news`. Use this for local runs or an external cron
(GitHub Actions, systemd timer, etc.).

## Setup

```bash
cd pipeline
cp .env.example .env   # fill in keys
npm install
```

Apply the SQL migration in `../supabase/migrations/` to your Supabase project
first (`supabase db push`).

## Commands

| Command | What it does |
|---------|----------------|
| `npm run ingest` | Full pipeline in-process (RSS → LLM → `articles` + GitHub) |
| `npm run ingest:dry` | Fetch + dedup only |
| `npm run trigger` | POST the deployed Edge Function |
| `npm run test:rss` | Parse a few public feeds (no secrets) |
| `node src/run.mjs --source politico-europe` | Limit to one seeded source |

## Cron example

```cron
0 */2 * * * cd /path/to/lexcockpit/pipeline && /usr/bin/npm run ingest >> /var/log/lex-ingest.log 2>&1
```

Or trigger the Edge Function:

```cron
0 */2 * * * cd /path/to/lexcockpit/pipeline && /usr/bin/npm run trigger
```
