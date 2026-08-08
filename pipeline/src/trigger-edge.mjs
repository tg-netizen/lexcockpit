#!/usr/bin/env node
/** Fire the deployed Supabase Edge Function (for external cron / GitHub Actions). */
import { loadEnv } from "./load-env.mjs"

loadEnv()

const edge =
  process.env.INGEST_EDGE_URL ??
  (process.env.SUPABASE_URL
    ? `${process.env.SUPABASE_URL.replace(/\/$/, "")}/functions/v1/ingest-news`
    : null)

if (!edge) {
  console.error("Set INGEST_EDGE_URL or SUPABASE_URL")
  process.exit(1)
}

const headers = { "Content-Type": "application/json" }
if (process.env.SUPABASE_SERVICE_ROLE_KEY) {
  headers.Authorization = `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`
}
if (process.env.CRON_SECRET) {
  headers["x-cron-secret"] = process.env.CRON_SECRET
}

const dry = process.argv.includes("--dry-run") ? "?dry_run=1" : ""
const res = await fetch(edge + dry, {
  method: "POST",
  headers,
  body: JSON.stringify({ trigger: "node-worker", at: new Date().toISOString() }),
})
const text = await res.text()
console.log(res.status, text)
if (!res.ok) process.exit(1)
