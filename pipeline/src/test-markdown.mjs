#!/usr/bin/env node
import { buildDraftMarkdown } from "./lib/github.mjs"
import { parseRss } from "./lib/rss.mjs"

let ok = true
function expect(cond, name) {
  console.log(cond ? `PASS  ${name}` : `FAIL  ${name}`)
  if (!cond) ok = false
}

const md = buildDraftMarkdown({
  title: "EU Sanctions Package XII",
  description: "Council adopts a new sanctions tranche.",
  topic: "Sanctions",
  tags: ["sanctions", "EU"],
  sourceUrl: "https://example.com/a",
  sourceName: "Politico Europe",
  sourcePublishedAt: "2026-08-08T10:00:00.000Z",
  body: "## What happened\n\nFacts.\n",
  relevanceScore: 0.91,
})

expect(md.markdown.includes("ai_generated: true"), "markdown marks ai_generated")
expect(md.markdown.includes("origin: ai-ingest"), "markdown marks origin")
expect(md.markdown.includes("review_required: true"), "markdown marks review_required")
expect(md.markdown.includes("status: draft"), "markdown is a draft")
expect(md.path.includes("content/articles/"), "path under content/articles")
expect(md.slug.includes("eu-sanctions-package-xii"), "slug derived from title")

const xml = `<?xml version="1.0"?>
<rss><channel>
<item>
  <title><![CDATA[Test & Title]]></title>
  <link>https://example.com/1</link>
  <description><![CDATA[<p>Hello world</p>]]></description>
  <pubDate>Fri, 08 Aug 2026 12:00:00 GMT</pubDate>
</item>
</channel></rss>`
const items = parseRss(xml)
expect(items.length === 1, "parses one item")
expect(items[0].title === "Test & Title", "decodes title entities/CDATA")
expect(items[0].link === "https://example.com/1", "reads link")
expect(items[0].snippet.includes("Hello world"), "strips HTML from snippet")

process.exit(ok ? 0 : 1)
