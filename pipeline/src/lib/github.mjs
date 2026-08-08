function slugify(input) {
  let s = input.toLowerCase()
  s = s.replace(/[äöüß]/g, (ch) => ({ ä: "ae", ö: "oe", ü: "ue", ß: "ss" }[ch] ?? ch))
  s = s.normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
  s = s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").replace(/-{2,}/g, "-")
  return s.slice(0, 80) || "untitled"
}

function yamlQuote(value) {
  if (/[:#{}[\],&*?|<>=!%@`]/.test(value) || /['"]/.test(value)) {
    return JSON.stringify(value)
  }
  return value.includes(" ") ? JSON.stringify(value) : value
}

export function buildDraftMarkdown(input) {
  const date = new Date().toISOString().slice(0, 10)
  const slug = `${date}-${slugify(input.title)}`
  const pathPrefix = process.env.GITHUB_CONTENT_PATH ?? "content/articles/"
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

export async function pushMarkdown(path, markdown, message) {
  const token = process.env.GITHUB_PAT
  const repo = process.env.GITHUB_REPO
  if (!token || !repo) {
    console.warn("GITHUB_PAT / GITHUB_REPO not set — skipping GitHub mirror")
    return null
  }
  const branch = process.env.GITHUB_BRANCH ?? "main"
  const api = `https://api.github.com/repos/${repo}/contents/${path}`
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "User-Agent": "LexCockpit-Ingest",
  }

  let sha
  const getRes = await fetch(`${api}?ref=${encodeURIComponent(branch)}`, { headers })
  if (getRes.status === 200) sha = (await getRes.json()).sha
  else if (getRes.status !== 404) {
    throw new Error(`GitHub GET ${getRes.status}: ${(await getRes.text()).slice(0, 200)}`)
  }

  const body = {
    message,
    content: Buffer.from(markdown, "utf8").toString("base64"),
    branch,
  }
  if (sha) body.sha = sha

  const putRes = await fetch(api, {
    method: "PUT",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  if (!putRes.ok) {
    throw new Error(`GitHub PUT ${putRes.status}: ${(await putRes.text()).slice(0, 300)}`)
  }
  const data = await putRes.json()
  return { path, commitSha: data.commit?.sha ?? "" }
}
