/** Push AI draft Markdown into the LexDigestGlobal content repo via GitHub Contents API. */

export interface GitHubPushResult {
  path: string
  commitSha: string
}

function env(name: string): string | undefined {
  return Deno.env.get(name) ?? undefined
}

function slugify(input: string): string {
  // Mirror LexCockpit Frontmatter.slugify spirit (umlaut transliteration).
  let s = input.toLowerCase()
  s = s.replace(/[äöüß]/g, (ch) =>
    ({ ä: "ae", ö: "oe", ü: "ue", ß: "ss" } as Record<string, string>)[ch] ?? ch
  )
  s = s.normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
  s = s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").replace(/-{2,}/g, "-")
  return s.slice(0, 80) || "untitled"
}

function todayISO(): string {
  return new Date().toISOString().slice(0, 10)
}

function yamlQuote(value: string): string {
  if (/[:#{}[\],&*?|<>=!%@`]/.test(value) || value.includes('"') || value.includes("'")) {
    return JSON.stringify(value)
  }
  return value.includes(" ") ? JSON.stringify(value) : value
}

export function buildDraftMarkdown(input: {
  title: string
  description: string
  topic: string
  tags: string[]
  sourceUrl: string
  sourceName: string
  sourcePublishedAt: string | null
  body: string
  relevanceScore: number
}): { path: string; markdown: string; slug: string } {
  const date = todayISO()
  const slug = `${date}-${slugify(input.title)}`
  const pathPrefix = env("GITHUB_CONTENT_PATH") ?? "content/articles/"
  const path = `${pathPrefix.replace(/\/?$/, "/")}${slug}.md`
  const tagsYaml = input.tags.length
    ? `\n${input.tags.map((t) => `  - ${yamlQuote(t)}`).join("\n")}`
    : " []"

  const markdown = `---
title: ${yamlQuote(input.title)}
type: brief
date: ${date}
slug: ${slugify(input.title)}
description: ${yamlQuote(input.description.slice(0, 240))}
topic: ${yamlQuote(input.topic)}
tags:${tagsYaml}
draft: true
status: draft
origin: ai-ingest
ai_generated: true
review_required: true
source_url: ${yamlQuote(input.sourceUrl)}
source_name: ${yamlQuote(input.sourceName)}
source_published_at: ${input.sourcePublishedAt ? yamlQuote(input.sourcePublishedAt) : '""'}
relevance_score: ${input.relevanceScore.toFixed(3)}
---

${input.body.trim()}
`
  return { path, markdown, slug }
}

export async function pushMarkdown(path: string, markdown: string, message: string): Promise<GitHubPushResult | null> {
  const token = env("GITHUB_PAT")
  const repo = env("GITHUB_REPO") // e.g. tg-netizen/lexdigestglobal-real-version
  if (!token || !repo) {
    console.warn("GITHUB_PAT / GITHUB_REPO not set — skipping GitHub mirror")
    return null
  }
  const branch = env("GITHUB_BRANCH") ?? "main"
  const api = `https://api.github.com/repos/${repo}/contents/${path}`

  // Check existing SHA for idempotent updates
  let sha: string | undefined
  const getRes = await fetch(`${api}?ref=${encodeURIComponent(branch)}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "LexCockpit-Ingest",
    },
  })
  if (getRes.status === 200) {
    const existing = await getRes.json()
    sha = existing.sha
  } else if (getRes.status !== 404) {
    throw new Error(`GitHub GET ${getRes.status}: ${(await getRes.text()).slice(0, 200)}`)
  }

  const body: Record<string, unknown> = {
    message,
    content: btoa(unescape(encodeURIComponent(markdown))),
    branch,
  }
  if (sha) body.sha = sha

  const putRes = await fetch(api, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": "LexCockpit-Ingest",
    },
    body: JSON.stringify(body),
  })
  if (!putRes.ok) {
    throw new Error(`GitHub PUT ${putRes.status}: ${(await putRes.text()).slice(0, 300)}`)
  }
  const data = await putRes.json()
  return {
    path,
    commitSha: data.commit?.sha ?? "",
  }
}
