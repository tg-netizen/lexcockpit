const CRITERIA = [
  "EU Regulation",
  "Sanctions",
  "Defence Supply Chains",
  "Geopolitics",
]

async function completeJSON(system, user) {
  const provider = (process.env.LLM_PROVIDER ??
    (process.env.ANTHROPIC_API_KEY ? "anthropic" : "openai")).toLowerCase()

  let raw
  if (provider === "anthropic") {
    const key = process.env.ANTHROPIC_API_KEY
    if (!key) throw new Error("ANTHROPIC_API_KEY not set")
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: process.env.ANTHROPIC_MODEL ?? "claude-3-5-haiku-latest",
        max_tokens: 2048,
        temperature: 0.2,
        system: system + "\nRespond with a single JSON object only — no markdown fences.",
        messages: [{ role: "user", content: user }],
      }),
    })
    if (!res.ok) throw new Error(`Anthropic ${res.status}: ${(await res.text()).slice(0, 300)}`)
    const data = await res.json()
    raw = (data.content ?? []).map((c) => c.text ?? "").join("")
  } else {
    const key = process.env.OPENAI_API_KEY
    if (!key) throw new Error("OPENAI_API_KEY not set")
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: process.env.OPENAI_MODEL ?? "gpt-4o-mini",
        temperature: 0.2,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: system },
          { role: "user", content: user },
        ],
      }),
    })
    if (!res.ok) throw new Error(`OpenAI ${res.status}: ${(await res.text()).slice(0, 300)}`)
    const data = await res.json()
    raw = data.choices?.[0]?.message?.content ?? "{}"
  }

  return JSON.parse(raw.replace(/^```json\s*/i, "").replace(/```$/i, "").trim())
}

export async function evaluateRelevance({ title, snippet, sourceName }) {
  const system = `You are the LexDigestGlobal relevance filter.
Evaluate news for HIGH strategic relevance to: ${CRITERIA.join(", ")}.
Ignore generic local crime, sports, celebrity, weather, and non-strategic domestic stories.
Return JSON: {"relevant":boolean,"score":0-1,"reason":string,"criteria":string[]}`
  try {
    const parsed = await completeJSON(
      system,
      `Source: ${sourceName}\nTitle: ${title}\nSnippet: ${snippet}`,
    )
    return {
      relevant: Boolean(parsed.relevant),
      score: Math.max(0, Math.min(1, Number(parsed.score) || 0)),
      reason: String(parsed.reason ?? ""),
      criteria: Array.isArray(parsed.criteria)
        ? parsed.criteria.map(String).filter((c) => CRITERIA.includes(c))
        : [],
    }
  } catch (err) {
    return {
      relevant: false,
      score: 0,
      reason: `evaluator_error: ${err.message}`,
      criteria: [],
    }
  }
}

export async function generateDraftSchema(input) {
  const system = `You are a LexDigestGlobal briefing editor.
Produce a structured article schema for human completion.
Return JSON with keys: working_title, core_fact_summary, strategic_impact,
outline (string[]), topic, tags (string[]), body_markdown.`

  const parsed = await completeJSON(
    system,
    `Source: ${input.sourceName}
URL: ${input.sourceUrl}
Published: ${input.publishedAt ?? "unknown"}
Matched criteria: ${input.criteria.join(", ") || "strategic"}
Title: ${input.title}
Snippet: ${input.snippet}`,
  )

  const outline = Array.isArray(parsed.outline)
    ? parsed.outline.map(String)
    : ["What happened", "Why it matters for Defence / Regulation", "Primary sources & next steps"]

  const body =
    (parsed.body_markdown ?? "").trim() ||
    `## What happened\n\n${parsed.core_fact_summary ?? input.snippet}\n\n` +
      `## Why it matters for Defence / Regulation\n\n${parsed.strategic_impact ?? ""}\n\n` +
      `<div class="draft-note">\n<p><strong>✎ AI Draft — Review Required</strong></p>\n` +
      `<ul><li>Verify every fact against the primary source</li>` +
      `<li>Rewrite for LexDigestGlobal voice before publishing</li></ul>\n</div>\n\n` +
      `## Primary source\n\n- [${input.sourceName}](${input.sourceUrl})\n`

  return {
    working_title: String(parsed.working_title ?? input.title).slice(0, 180),
    core_fact_summary: String(parsed.core_fact_summary ?? input.snippet).slice(0, 2000),
    strategic_impact: String(parsed.strategic_impact ?? "").slice(0, 2000),
    outline,
    topic: String(parsed.topic ?? "Geopolitics"),
    tags: Array.isArray(parsed.tags) ? parsed.tags.map(String).slice(0, 12) : [],
    body_markdown: body,
  }
}

export { CRITERIA }
