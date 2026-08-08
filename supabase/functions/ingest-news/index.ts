/**
 * LexCockpit content ingestion pipeline.
 *
 * Default mode = scan_only (FREE):
 *   A. Fetch RSS from `news_sources`
 *   B. Dedup by `ingested_items.source_url`
 *   C. Keyword relevance filter (no LLM)
 *   D. Queue interesting hits on the waiting list (status = `queued`)
 *
 * Optional later (PIPELINE_MODE=full + API keys):
 *   E. LLM filter + draft generation → `articles` + optional GitHub mirror
 *
 * Auth: Authorization Bearer service_role OR header `x-cron-secret` == CRON_SECRET
 */
import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchFeed } from "../_shared/rss.ts"
import { scoreKeywords } from "../_shared/keywords.ts"
import { evaluateRelevance, generateDraftSchema } from "../_shared/llm.ts"
import { buildDraftMarkdown, pushMarkdown } from "../_shared/github.ts"

/* No CORS headers, on purpose. This is a machine endpoint — pg_cron, GitHub
   Actions and curl call it, and none of them care about CORS. The previous
   `Access-Control-Allow-Origin: *` invited any web page to fire requests at it,
   a free distributed guessing machine for CRON_SECRET. Supabase's gateway adds
   its own CORS headers in front of this, which is out of our hands; not adding
   a second permissive set is. */
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}

/** Length-independent comparison, so response timing cannot leak the secret
    one character at a time. Comparing lengths first is standard practice. */
function secretsMatch(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/**
 * The real gate in front of this function.
 *
 * The Supabase gateway checks the Authorization header first (verify_jwt is ON
 * for the deployed function), but the anon key satisfies that and the anon key
 * is public by design — it ships inside the Mac app. So the gateway narrows the
 * field; this narrows it to callers who actually hold a secret.
 *
 * This used to end with `if (!cronSecret && !service) return true` — an
 * unconfigured deployment was open to the internet. Hosted Supabase injects
 * SUPABASE_SERVICE_ROLE_KEY automatically, so that branch was hard to reach in
 * production, but it was live under `supabase functions serve` and on any
 * self-hosted deploy. Missing configuration now denies.
 */
function authorized(req: Request): { ok: boolean; reason?: string } {
  const cronSecret = Deno.env.get("CRON_SECRET") ?? ""
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  if (!cronSecret && !service) {
    return { ok: false, reason: "not configured — set CRON_SECRET" }
  }
  const headerSecret = req.headers.get("x-cron-secret") ?? ""
  if (cronSecret && headerSecret && secretsMatch(headerSecret, cronSecret)) {
    return { ok: true }
  }
  const token = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "").trim()
  if (service && token && secretsMatch(token, service)) return { ok: true }
  return { ok: false, reason: "bad or missing credentials" }
}

function adminClient() {
  const url = Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing")
  return createClient(url, key, { auth: { persistSession: false } })
}

/**
 * scan_only = free waiting list; full = LLM drafts (needs API keys).
 *
 * The `?mode=` query parameter used to be returned unchecked, while only the
 * environment path required an API key to be present. Anything that could
 * reach this function could therefore force paid mode with one query string,
 * and neither README mentioned it. Both paths now go through the same gate:
 * full mode requires a key, whoever asks and however they ask.
 */
function resolveMode(req: Request): "scan_only" | "full" {
  const hasKey = !!(Deno.env.get("OPENAI_API_KEY") || Deno.env.get("ANTHROPIC_API_KEY"))
  const q = new URL(req.url).searchParams.get("mode")
  const wanted = (q === "full" || q === "scan_only")
    ? q
    : (Deno.env.get("PIPELINE_MODE") ?? "scan_only").toLowerCase()
  return (wanted === "full" && hasKey) ? "full" : "scan_only"
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return json({ error: "Method not allowed" }, 405)
  }
  const auth = authorized(req)
  if (!auth.ok) return json({ error: "Unauthorized", detail: auth.reason }, 401)

  const supabase = adminClient()
  const dryRun = new URL(req.url).searchParams.get("dry_run") === "1"
  const mode = resolveMode(req)

  const { data: run, error: runErr } = await supabase
    .from("pipeline_runs")
    .insert({ status: "running", details: { mode } })
    .select("id")
    .single()
  if (runErr) return json({ error: runErr.message }, 500)
  const runId = run.id as string

  let sourcesScanned = 0
  let itemsFetched = 0
  let itemsNew = 0
  let itemsRelevant = 0
  let itemsQueued = 0
  let draftsCreated = 0
  const errors: string[] = []

  try {
    const { data: sources, error: srcErr } = await supabase
      .from("news_sources")
      .select("*")
      .eq("enabled", true)
    if (srcErr) throw srcErr

    for (const source of sources ?? []) {
      sourcesScanned++
      let items
      try {
        items = await fetchFeed(source.feed_url, source.max_items_per_run ?? 15)
      } catch (err) {
        errors.push(`${source.slug}: ${err instanceof Error ? err.message : String(err)}`)
        continue
      }
      itemsFetched += items.length

      for (const item of items) {
        /* `source_url` carries a UNIQUE btree index, and a btree entry cannot
           exceed roughly 2704 bytes. One broken or hostile feed item with an
           absurd link would otherwise fail at the index and be reported as an
           opaque error. Skip it here and name it. */
        if (!item.link || new TextEncoder().encode(item.link).length > 2000) {
          errors.push(`${source.slug}: skipped an item with a missing or over-long link`)
          continue
        }

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
          if (insErr.code === "23505") continue
          errors.push(`insert ${item.link}: ${insErr.message}`)
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

        // --- Free keyword gate (always runs) ---
        /* sourceName is deliberately not passed: the scorer no longer votes
           on a feed's own title (see keywords.ts). Feeding it in made every
           item from "Defence News" relevant by construction. */
        const kw = scoreKeywords({ title: item.title, snippet: item.snippet })

        if (mode === "scan_only") {
          if (kw.relevant) {
            itemsRelevant++
            itemsQueued++
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

        // --- Full mode (paid LLM) — only for keyword survivors ---
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

        await supabase.from("ingested_items").update({
          status: "evaluated",
          is_relevant: verdict.relevant,
          relevance_score: score,
          relevance_reason: `${kw.reason} | llm: ${verdict.reason}`,
        }).eq("id", ingested.id)

        if (!verdict.relevant || verdict.score < 0.55) {
          // Keep on waiting list instead of hard-rejecting keyword hits.
          itemsRelevant++
          itemsQueued++
          await supabase.from("ingested_items").update({
            status: "queued",
            is_relevant: true,
          }).eq("id", ingested.id)
          continue
        }

        itemsRelevant++
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

          let githubPath: string | null = null
          let githubSha: string | null = null
          try {
            const pushed = await pushMarkdown(
              md.path,
              md.markdown,
              `content: ai-draft ${md.slug}`,
            )
            if (pushed) {
              githubPath = pushed.path
              githubSha = pushed.commitSha
            }
          } catch (ghErr) {
            errors.push(`github ${md.slug}: ${ghErr instanceof Error ? ghErr.message : String(ghErr)}`)
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
              source_metadata: {
                feed: source.feed_url,
                source_slug: source.slug,
                region: source.region,
              },
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
            errors.push(`article ${md.slug}: ${artErr.message}`)
            continue
          }

          await supabase.from("ingested_items").update({
            status: "drafted",
            article_id: article.id,
          }).eq("id", ingested.id)

          draftsCreated++
        } catch (genErr) {
          const msg = genErr instanceof Error ? genErr.message : String(genErr)
          await supabase.from("ingested_items").update({
            status: "queued",
            error_message: msg,
            is_relevant: true,
            relevance_score: score,
          }).eq("id", ingested.id)
          itemsQueued++
          errors.push(`generate ${item.link}: ${msg}`)
        }
      }
    }

    const status = errors.length === 0 ? "ok" : (itemsQueued > 0 || draftsCreated > 0 || itemsNew > 0 ? "partial" : "error")
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
    }).eq("id", runId)

    return json({
      run_id: runId,
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
      review_queue: "select * from review_queue",
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await supabase.from("pipeline_runs").update({
      finished_at: new Date().toISOString(),
      status: "error",
      sources_scanned: sourcesScanned,
      items_fetched: itemsFetched,
      items_new: itemsNew,
      items_relevant: itemsRelevant,
      drafts_created: draftsCreated,
      error_message: message,
      details: { mode, items_queued: itemsQueued },
    }).eq("id", runId)
    return json({ run_id: runId, mode, error: message }, 500)
  }
})
