/** Minimal RSS/Atom parser — no npm deps (works in Deno Edge Functions). */

export interface RssItem {
  title: string
  link: string
  snippet: string
  publishedAt: string | null
  guid: string | null
}

/* Numeric entities are decoded generically rather than one at a time. The
   hand-written list covered &#39; and stopped there, so a Politico headline
   arrived in the app reading
     Germany battling &#8220;daily&#8221; hybrid warfare attacks
   — the curly quotes publishers actually use. Named entities keep their
   explicit list (there are ~2000 of them and this parser needs five), but
   &#NNN; and &#xHH; are mechanical and there is no reason to enumerate them.
   Order matters: numerics run BEFORE &amp;, so a literal "&amp;#8220;" is not
   collapsed into a quote it never was. */
function decodeNumeric(s: string): string {
  return s
    .replace(/&#(\d+);/g, (_, d) => safeChar(parseInt(d, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => safeChar(parseInt(h, 16)))
    /* A dangling entity with no semicolon is the tail of one that a length
       limit cut in half. A real headline arrived as
         "…countermeasure sanctions list &#0"
       Decoding it is impossible and showing it is noise, so it goes. */
    .replace(/&#x?[0-9a-fA-F]*$/, "")
}

/* Code points outside the Unicode range would throw, and C0 control characters
   are never what a headline meant — a feed that ships either is broken, but it
   should not take the run down with it or plant invisible junk in a title. */
function safeChar(code: number): string {
  if (!Number.isFinite(code) || code > 0x10ffff) return ""
  if (code < 32 && code !== 9 && code !== 10) return ""
  try { return String.fromCodePoint(code) } catch { return "" }
}

function decodeEntities(s: string): string {
  return decodeNumeric(s)
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
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
