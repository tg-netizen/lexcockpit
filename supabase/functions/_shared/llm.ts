/** LLM client — Anthropic Claude 3.5 Haiku or OpenAI GPT-4o-mini. */

export interface RelevanceVerdict {
  relevant: boolean
  score: number
  reason: string
  criteria: string[]
}

export interface DraftSchema {
  working_title: string
  core_fact_summary: string
  strategic_impact: string
  outline: string[]
  topic: string
  tags: string[]
  body_markdown: string
}

const CRITERIA = [
  "EU Regulation",
  "Sanctions",
  "Defence Supply Chains",
  "Geopolitics",
]

function env(name: string): string | undefined {
  return Deno.env.get(name) ?? undefined
}

async function callOpenAI(system: string, user: string): Promise<string> {
  const key = env("OPENAI_API_KEY")
  if (!key) throw new Error("OPENAI_API_KEY not set")
  const model = env("OPENAI_MODEL") ?? "gpt-4o-mini"
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      temperature: 0.2,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
    }),
  })
  if (!res.ok) {
    throw new Error(`OpenAI ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }
  const data = await res.json()
  return data.choices?.[0]?.message?.content ?? "{}"
}

async function callAnthropic(system: string, user: string): Promise<string> {
  const key = env("ANTHROPIC_API_KEY")
  if (!key) throw new Error("ANTHROPIC_API_KEY not set")
  const model = env("ANTHROPIC_MODEL") ?? "claude-3-5-haiku-latest"
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: 2048,
      temperature: 0.2,
      system,
      messages: [{ role: "user", content: user }],
    }),
  })
  if (!res.ok) {
    throw new Error(`Anthropic ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }
  const data = await res.json()
  const text = data.content?.map((c: { text?: string }) => c.text ?? "").join("") ?? "{}"
  return text
}

async function completeJSON(system: string, user: string): Promise<unknown> {
  const provider = (env("LLM_PROVIDER") ?? (env("ANTHROPIC_API_KEY") ? "anthropic" : "openai"))
    .toLowerCase()
  let raw: string
  if (provider === "anthropic") {
    raw = await callAnthropic(
      system + "\nRespond with a single JSON object only — no markdown fences.",
      user,
    )
  } else {
    raw = await callOpenAI(system, user)
  }
  const cleaned = raw.replace(/^```json\s*/i, "").replace(/```$/i, "").trim()
  return JSON.parse(cleaned)
}

export async function evaluateRelevance(input: {
  title: string
  snippet: string
  sourceName: string
}): Promise<RelevanceVerdict> {
  const system = `You are the LexDigestGlobal relevance filter.
Evaluate news for HIGH strategic relevance to: ${CRITERIA.join(", ")}.
Ignore generic local crime, sports, celebrity, weather, and non-strategic domestic stories.
Return JSON: {"relevant":boolean,"score":0-1,"reason":string,"criteria":string[]}`

  const user = `Source: ${input.sourceName}
Title: ${input.title}
Snippet: ${input.snippet}`

  try {
    const parsed = await completeJSON(system, user) as RelevanceVerdict
    return {
      relevant: Boolean(parsed.relevant),
      score: Math.max(0, Math.min(1, Number(parsed.score) || 0)),
      reason: String(parsed.reason ?? ""),
      criteria: Array.isArray(parsed.criteria)
        ? parsed.criteria.map(String).filter((c) => CRITERIA.includes(c))
        : [],
    }
  } catch (err) {
    // Fail closed — do not create drafts on evaluator failure.
    return {
      relevant: false,
      score: 0,
      reason: `evaluator_error: ${err instanceof Error ? err.message : String(err)}`,
      criteria: [],
    }
  }
}

export async function generateDraftSchema(input: {
  title: string
  snippet: string
  sourceUrl: string
  sourceName: string
  publishedAt: string | null
  criteria: string[]
}): Promise<DraftSchema> {
  const system = `You are a LexDigestGlobal briefing editor.
Produce a structured article schema for human completion.
Tone: precise, strategic, EU/defence/regulation-aware. No hype.
Return JSON with keys:
working_title, core_fact_summary, strategic_impact,
outline (string array of section headings),
topic (one of: EU Law & Regulation, Sanctions, Defence, Geopolitics, Economy & Trade),
tags (string array),
body_markdown (markdown with sections: What Happened, Why It Matters, Outline skeleton with draft-note HTML divs for the human editor).`

  const user = `Source: ${input.sourceName}
URL: ${input.sourceUrl}
Published: ${input.publishedAt ?? "unknown"}
Matched criteria: ${input.criteria.join(", ") || "strategic"}
Title: ${input.title}
Snippet: ${input.snippet}`

  const parsed = await completeJSON(system, user) as Partial<DraftSchema>
  const outline = Array.isArray(parsed.outline) ? parsed.outline.map(String) : [
    "What happened",
    "Why it matters for Defence / Regulation",
    "Primary sources & next steps",
  ]
  const body = parsed.body_markdown?.trim() || defaultBodyMarkdown({
    core: String(parsed.core_fact_summary ?? input.snippet),
    impact: String(parsed.strategic_impact ?? ""),
    outline,
    sourceUrl: input.sourceUrl,
    sourceName: input.sourceName,
  })

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

export function defaultBodyMarkdown(opts: {
  core: string
  impact: string
  outline: string[]
  sourceUrl: string
  sourceName: string
}): string {
  const skeleton = opts.outline.map((h) => `## ${h}\n\n<!-- TODO: expand -->\n`).join("\n")
  return `## What happened

${opts.core}

## Why it matters for Defence / Regulation

${opts.impact || "_Strategic impact to be filled in._"}

<div class="draft-note">
<p><strong>✎ AI Draft — Review Required</strong></p>
<ul>
<li>Verify every fact against the primary source</li>
<li>Add CELEX / Official Journal / official statements where relevant</li>
<li>Rewrite for LexDigestGlobal voice before publishing</li>
</ul>
</div>

## Outline

${skeleton}

## Primary source

- [${opts.sourceName}](${opts.sourceUrl})
`
}

export { CRITERIA }
