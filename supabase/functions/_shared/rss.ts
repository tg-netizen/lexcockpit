/** Minimal RSS/Atom parser — no npm deps (works in Deno Edge Functions). */

export interface RssItem {
  title: string
  link: string
  snippet: string
  publishedAt: string | null
  guid: string | null
}

function decodeEntities(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

function tag(block: string, name: string): string | null {
  const re = new RegExp(
    `<${name}[^>]*>([\\s\\S]*?)</${name}>|<${name}[^>]*/>`,
    "i",
  )
  const m = block.match(re)
  if (!m) return null
  return m[1] ? decodeEntities(m[1]) : null
}

function attr(block: string, name: string, attrName: string): string | null {
  const re = new RegExp(`<${name}[^>]*\\s${attrName}=["']([^"']+)["'][^>]*/?>`, "i")
  const m = block.match(re)
  return m?.[1] ?? null
}

function splitItems(xml: string): string[] {
  const items = xml.match(/<item[\s>][\s\S]*?<\/item>/gi) ?? []
  if (items.length) return items
  return xml.match(/<entry[\s>][\s\S]*?<\/entry>/gi) ?? []
}

export function parseRss(xml: string): RssItem[] {
  return splitItems(xml).map((block) => {
    const title = tag(block, "title") ?? "(untitled)"
    const link =
      tag(block, "link") ??
      attr(block, "link", "href") ??
      tag(block, "guid") ??
      ""
    const snippet =
      tag(block, "description") ??
      tag(block, "summary") ??
      tag(block, "content") ??
      tag(block, "content:encoded") ??
      ""
    const publishedAt =
      tag(block, "pubDate") ??
      tag(block, "published") ??
      tag(block, "updated") ??
      tag(block, "dc:date")
    const guid = tag(block, "guid") ?? tag(block, "id")
    return {
      title,
      link: link.trim(),
      snippet: snippet.slice(0, 600),
      publishedAt: publishedAt ? new Date(publishedAt).toISOString() : null,
      guid,
    }
  }).filter((i) => i.link.length > 0)
}

export async function fetchFeed(feedUrl: string, maxItems: number): Promise<RssItem[]> {
  const res = await fetch(feedUrl, {
    headers: {
      "User-Agent": "LexCockpit-Ingest/1.0 (+https://lexdigestglobal.com)",
      Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
    },
  })
  if (!res.ok) {
    throw new Error(`RSS fetch failed ${res.status} for ${feedUrl}`)
  }
  const xml = await res.text()
  return parseRss(xml).slice(0, maxItems)
}
