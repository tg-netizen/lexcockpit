#!/usr/bin/env node
/**
 * In-process Node worker — default FREE scan-only waiting list.
 *
 *   npm run ingest          → scan_only (keywords → review_queue)
 *   npm run ingest:full     → paid LLM drafts (needs API keys)
 *   npm run ingest:dry      → fetch + dedup only
 *   node src/run.mjs --source politico-europe
 */
import { createClient } from "@supabase/supabase-js"
import { loadEnv } from "./load-env.mjs"
import { fetchFeed } from "./lib/rss.mjs"
import { scoreKeywords } from "./lib/keywords.mjs"
import { evaluateRelevance, generateDraftSchema } from "./lib/llm.mjs"
import { buildDraftMarkdown, pushMarkdown } from "./lib/github.mjs"

loadEnv()

const dryRun = process.argv.includes("--dry-run")
const wantFull = process.argv.includes("--full")
const sourceFilter = (() => {
  const i = process.argv.indexOf("--source")
  return i >= 0 ? process.argv[i + 1] : null
})()

const hasLlm = Boolean(process.env.OPENAI_API_KEY || process.env.ANTHROPIC_API_KEY)
const envMode = (process.env.PIPELINE_MODE ?? "scan_only").toLowerCase()
const mode = wantFull || envMode === "full"
  ? (hasLlm ? "full" : "scan_only")
  : "scan_only"

if (wantFull && !hasLlm) {
  console.warn("⚠ --full requested but no LLM API key set → falling back to scan_only")
}

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !key) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (see .env.example)")
  process.exit(1)
}

const supabase = createClient(url, key, { auth: { persistSession: false } })

const { data: run, error: runErr } = await supabase
  .from("pipeline_runs")
  .insert({ status: "running", details: { mode } })
  .select("id")
  .single()
if (runErr) {
  console.error("pipeline_runs insert failed:", runErr.message)
  console.error("Did you run both SQL migrations in the Supabase SQL Editor?")
  process.exit(1)
}

let sourcesScanned = 0
let itemsFetched = 0
let itemsNew = 0
let itemsRelevant = 0
let itemsQueued = 0
let draftsCreated = 0
const errors = []

console.log(`Mode: ${mode}${dryRun ? " (dry-run)" : ""}`)

try {
  let q = supabase.from("news_sources").select("*").eq("enabled", true)
  if (sourceFilter) q = q.eq("slug", sourceFilter)
  const { data: sources, error: srcErr } = await q
  if (srcErr) throw srcErr

  for (const source of sources ?? []) {
    sourcesScanned++
    console.log(`→ ${source.name}`)
    let items
    try {
      items = await fetchFeed(source.feed_url, source.max_items_per_run ?? 15)
    } catch (err) {
      errors.push(`${source.slug}: ${err.message}`)
      console.warn("  fetch error:", err.message)
      continue
    }
    itemsFetched += items.length
    console.log(`  ${items.length} items`)

    for (const item of items) {
      const { data: existing } = await supabase
        .from("ingested_items")
        .select("id")
        .eq("source_url", item.link)
        .maybeSingle()
      if (existing) continue

      itemsNew++
      const { data: ingested, error: insErr } = await supabase
        .from("ingested_items")
        .insert({
          source_id: source.id,
          source_url: item.link,
          title: item.title,
          snippet: item.snippet,
          published_at: item.publishedAt,
          status: "fetched",
          raw: { guid: item.guid },
        })
        .select("id")
        .single()
      if (insErr) {
        if (insErr.code !== "23505") errors.push(insErr.message)
        continue
      }

      if (dryRun) {
        await supabase.from("ingested_items").update({
          status: "evaluated",
          is_relevant: false,
          relevance_reason: "dry_run",
          relevance_score: 0,
        }).eq("id", ingested.id)
        continue
      }

      /* sourceName is deliberately not passed: the scorer no longer votes on
         a feed's own title (see lib/keywords.mjs). */
      const kw = scoreKeywords({ title: item.title, snippet: item.snippet })

      if (mode === "scan_only") {
        if (kw.relevant) {
          itemsRelevant++
          itemsQueued++
          console.log(`  ★ queued (${kw.score}): ${item.title.slice(0, 80)}`)
          await supabase.from("ingested_items").update({
            status: "queued",
            is_relevant: true,
            relevance_score: kw.score,
            relevance_reason: kw.reason,
            raw: {
              guid: item.guid,
              matched: kw.matched,
              criteria: kw.criteria,
              mode: "scan_only",
            },
          }).eq("id", ingested.id)
        } else {
          await supabase.from("ingested_items").update({
            status: "rejected",
            is_relevant: false,
            relevance_score: kw.score,
            relevance_reason: kw.reason,
          }).eq("id", ingested.id)
        }
        continue
      }

      // full mode
      if (!kw.relevant) {
        await supabase.from("ingested_items").update({
          status: "rejected",
          is_relevant: false,
          relevance_score: kw.score,
          relevance_reason: kw.reason,
        }).eq("id", ingested.id)
        continue
      }

      const verdict = await evaluateRelevance({
        title: item.title,
        snippet: item.snippet,
        sourceName: source.name,
      })
      const score = Math.max(kw.score, verdict.score)
      const criteria = [...new Set([...kw.criteria, ...verdict.criteria])]

      if (!verdict.relevant || verdict.score < 0.55) {
        itemsRelevant++
        itemsQueued++
        await supabase.from("ingested_items").update({
          status: "queued",
          is_relevant: true,
          relevance_score: score,
          relevance_reason: `${kw.reason} | llm: ${verdict.reason}`,
        }).eq("id", ingested.id)
        continue
      }

      itemsRelevant++
      console.log(`  ✓ drafting (${score}): ${item.title.slice(0, 80)}`)
      try {
        const schema = await generateDraftSchema({
          title: item.title,
          snippet: item.snippet,
          sourceUrl: item.link,
          sourceName: source.name,
          publishedAt: item.publishedAt,
          criteria,
        })
        const md = buildDraftMarkdown({
          title: schema.working_title,
          description: schema.core_fact_summary,
          topic: schema.topic,
          tags: schema.tags,
          sourceUrl: item.link,
          sourceName: source.name,
          sourcePublishedAt: item.publishedAt,
          body: schema.body_markdown,
          relevanceScore: score,
        })

        let githubPath = null
        let githubSha = null
        try {
          const pushed = await pushMarkdown(md.path, md.markdown, `content: ai-draft ${md.slug}`)
          if (pushed) {
            githubPath = pushed.path
            githubSha = pushed.commitSha
          }
        } catch (ghErr) {
          errors.push(`github: ${ghErr.message}`)
        }

        const { data: article, error: artErr } = await supabase
          .from("articles")
          .insert({
            working_title: schema.working_title,
            slug: md.slug,
            status: "concept",
            origin: "ai-ingest",
            ai_generated: true,
            review_required: true,
            core_fact_summary: schema.core_fact_summary,
            strategic_impact: schema.strategic_impact,
            outline: schema.outline,
            body_markdown: md.markdown,
            source_url: item.link,
            source_name: source.name,
            source_published_at: item.publishedAt,
            source_metadata: { feed: source.feed_url, source_slug: source.slug },
            relevance_score: score,
            relevance_criteria: criteria,
            topic: schema.topic,
            tags: schema.tags,
            github_path: githubPath,
            github_commit_sha: githubSha,
            ingested_item_id: ingested.id,
          })
          .select("id")
          .single()

        if (artErr) {
          await supabase.from("ingested_items").update({
            status: "queued",
            error_message: artErr.message,
          }).eq("id", ingested.id)
          itemsQueued++
          errors.push(artErr.message)
          continue
        }

        await supabase.from("ingested_items").update({
          status: "drafted",
          article_id: article.id,
        }).eq("id", ingested.id)
        draftsCreated++
      } catch (genErr) {
        await supabase.from("ingested_items").update({
          status: "queued",
          error_message: genErr.message,
          is_relevant: true,
        }).eq("id", ingested.id)
        itemsQueued++
        errors.push(genErr.message)
      }
    }
  }

  const status = errors.length === 0 ? "ok" : (itemsQueued || draftsCreated || itemsNew ? "partial" : "error")
  await supabase.from("pipeline_runs").update({
    finished_at: new Date().toISOString(),
    status,
    sources_scanned: sourcesScanned,
    items_fetched: itemsFetched,
    items_new: itemsNew,
    items_relevant: itemsRelevant,
    drafts_created: draftsCreated,
    error_message: errors.length ? errors.slice(0, 8).join(" | ") : null,
    details: { errors: errors.slice(0, 40), dry_run: dryRun, mode, items_queued: itemsQueued },
  }).eq("id", run.id)

  console.log(JSON.stringify({
    run_id: run.id,
    mode,
    status,
    sources_scanned: sourcesScanned,
    items_fetched: itemsFetched,
    items_new: itemsNew,
    items_relevant: itemsRelevant,
    items_queued: itemsQueued,
    drafts_created: draftsCreated,
    errors,
    dry_run: dryRun,
  }, null, 2))
  console.log("\nWaiting list: SELECT * FROM review_queue;")
} catch (err) {
  await supabase.from("pipeline_runs").update({
    finished_at: new Date().toISOString(),
    status: "error",
    error_message: err.message,
    sources_scanned: sourcesScanned,
    items_fetched: itemsFetched,
    items_new: itemsNew,
    items_relevant: itemsRelevant,
    drafts_created: draftsCreated,
    details: { mode, items_queued: itemsQueued },
  }).eq("id", run.id)
  console.error(err)
  process.exit(1)
}
