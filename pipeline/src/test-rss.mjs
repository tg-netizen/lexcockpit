#!/usr/bin/env node
/** Smoke-test RSS parsing against seeded feed URLs (no DB / LLM needed). */
import { fetchFeed } from "./lib/rss.mjs"

const feeds = [
  ["Politico Europe", "https://www.politico.eu/feed/"],
  ["Defence News", "https://www.defensenews.com/arc/outboundfeeds/rss/?outputType=xml"],
  ["Tagesschau", "https://www.tagesschau.de/index~rss2.xml"],
]

let failed = 0
for (const [name, url] of feeds) {
  try {
    const items = await fetchFeed(url, 3)
    console.log(`PASS  ${name}: ${items.length} items — ${items[0]?.title?.slice(0, 70) ?? "(none)"}`)
    if (!items.length) failed++
  } catch (err) {
    failed++
    console.log(`FAIL  ${name}: ${err.message}`)
  }
}
process.exit(failed ? 1 : 0)
