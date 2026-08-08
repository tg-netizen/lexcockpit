/** Minimal RSS/Atom parser for the Node worker. */

export function parseRss(xml) {
  const blocks =
    xml.match(/<item[\s>][\s\S]*?<\/item>/gi) ??
    xml.match(/<entry[\s>][\s\S]*?<\/entry>/gi) ??
    []

  return blocks
    .map((block) => {
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
        ""
      const publishedAt =
        tag(block, "pubDate") ??
        tag(block, "published") ??
        tag(block, "updated")
      return {
        title,
        link: link.trim(),
        snippet: decode(snippet).slice(0, 600),
        publishedAt: publishedAt ? new Date(publishedAt).toISOString() : null,
        guid: tag(block, "guid") ?? tag(block, "id"),
      }
    })
    .filter((i) => i.link.length > 0)
}

export async function fetchFeed(feedUrl, maxItems = 15) {
  const res = await fetch(feedUrl, {
    headers: {
      "User-Agent": "LexCockpit-Ingest/1.0 (+https://lexdigestglobal.com)",
      Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
    },
  })
  if (!res.ok) throw new Error(`RSS ${res.status} for ${feedUrl}`)
  return parseRss(await res.text()).slice(0, maxItems)
}

function decode(s) {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

function tag(block, name) {
  const m = block.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, "i"))
  return m ? decode(m[1]) : null
}

function attr(block, name, attrName) {
  const m = block.match(
    new RegExp(`<${name}[^>]*\\s${attrName}=["']([^"']+)["'][^>]*/?>`, "i"),
  )
  return m?.[1] ?? null
}
