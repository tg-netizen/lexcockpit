/**
 * LexCockpit automated content ingestion pipeline.
 *
 * Steps:
 *  A. Fetch RSS from `news_sources`
 *  B. Dedup by `ingested_items.source_url`
 *  C. LLM relevance filter (LexDigestGlobal criteria)
 *  D. Generate structured draft → `articles` (status concept/draft)
 *  E. Optionally mirror Markdown into the GitHub content repo for Cockpit UI
 *
 * Auth: Authorization Bearer service_role OR header `x-cron-secret` == CRON_SECRET
 */
import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchFeed } from "../_shared/rss.ts"
import { evaluateRelevance, generateDraftSchema } from "../_shared/llm.ts"
import { buildDraftMarkdown, pushMarkdown } from "../_shared/github.ts"

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  })
}

function authorized(req: Request): boolean {
  const cronSecret = Deno.env.get("CRON_SECRET")
  const headerSecret = req.headers.get("x-cron-secret")
  if (cronSecret && headerSecret && headerSecret === cronSecret) return true

  const auth = req.headers.get("Authorization") ?? ""
  const token = auth.replace(/^Bearer\s+/i, "").trim()
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  if (service && token && token === service) return true

  // Local `supabase functions serve` convenience when CRON_SECRET unset.
  if (!cronSecret && !service) return true
  return false
}

function adminClient() {
  const url = Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing")
  return createClient(url, key, { auth: { persistSession: false } })
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (req.method !== "POST" && req.method !== "GET") {
    return json({ error: "Method not allowed" }, 405)
  }
  if (!authorized(req)) return json({ error: "Unauthorized" }, 401)

  const supabase = adminClient()
  const dryRun = new URL(req.url).searchParams.get("dry_run") === "1"

  const { data: run, error: runErr } = await supabase
    .from("pipeline_runs")
    .insert({ status: "running" })
    .select("id")
    .single()
  if (runErr) return json({ error: runErr.message }, 500)
  const runId = run.id as string

  let sourcesScanned = 0
  let itemsFetched = 0
  let itemsNew = 0
  let itemsRelevant = 0
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
        // Dedup
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
          // Unique race → skip
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

        const verdict = await evaluateRelevance({
          title: item.title,
          snippet: item.snippet,
          sourceName: source.name,
        })

        await supabase.from("ingested_items").update({
          status: "evaluated",
          is_relevant: verdict.relevant,
          relevance_score: verdict.score,
          relevance_reason: verdict.reason,
        }).eq("id", ingested.id)

        if (!verdict.relevant || verdict.score < 0.55) {
          await supabase.from("ingested_items").update({ status: "rejected" }).eq("id", ingested.id)
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
            criteria: verdict.criteria,
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
            relevanceScore: verdict.score,
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
              relevance_score: verdict.score,
              relevance_criteria: verdict.criteria,
              topic: schema.topic,
              tags: schema.tags,
              github_path: githubPath,
              github_commit_sha: githubSha,
              ingested_item_id: ingested.id,
            })
            .select("id")
            .single()

          if (artErr) {
            // slug collision — keep ingested, mark error
            await supabase.from("ingested_items").update({
              status: "error",
              error_message: artErr.message,
            }).eq("id", ingested.id)
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
            status: "error",
            error_message: msg,
          }).eq("id", ingested.id)
          errors.push(`generate ${item.link}: ${msg}`)
        }
      }
    }

    const status = errors.length === 0 ? "ok" : (draftsCreated > 0 || itemsNew > 0 ? "partial" : "error")
    await supabase.from("pipeline_runs").update({
      finished_at: new Date().toISOString(),
      status,
      sources_scanned: sourcesScanned,
      items_fetched: itemsFetched,
      items_new: itemsNew,
      items_relevant: itemsRelevant,
      drafts_created: draftsCreated,
      error_message: errors.length ? errors.slice(0, 8).join(" | ") : null,
      details: { errors: errors.slice(0, 40), dry_run: dryRun },
    }).eq("id", runId)

    return json({
      run_id: runId,
      status,
      sources_scanned: sourcesScanned,
      items_fetched: itemsFetched,
      items_new: itemsNew,
      items_relevant: itemsRelevant,
      drafts_created: draftsCreated,
      errors,
      dry_run: dryRun,
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
    }).eq("id", runId)
    return json({ run_id: runId, error: message }, 500)
  }
})
