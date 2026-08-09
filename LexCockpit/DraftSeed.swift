import Foundation

/// Turning a cluster of queue items into the start of a brief.
///
/// The Desk learned to say "3 items circling Belarus, 3 sources" — and then
/// it stopped. You saw the cluster and left the app to write, which made the
/// most useful thing on the screen a dead end.
///
/// This closes it, under one rule: **the app positions raw material and
/// writes no prose.** Everything below the frontmatter is either the
/// template's own scaffolding or a verbatim quote from the feed, carrying
/// the outlet it came from and the day it was read. The app never
/// paraphrases and never summarises, because a paraphrase of a headline it
/// does not understand is precisely how a false claim reaches a page.
///
/// Two smaller honesties follow from the same rule:
///
///  · **The title is a placeholder.** The app counted the items; it did not
///    read them. It can offer the word they share and nothing more.
///  · **Sources are seeded `secondary`.** A feed item is somebody's
///    reporting *about* a document, not the document. Promoting it to
///    `primary` is a judgement, so it stays with the author.
enum DraftSeed {

    /// How many different outlets are behind these items.
    static func outlets(_ items: [ReviewQueueItem]) -> [String] {
        var seen: [String] = []
        for it in items {
            let name = (it.source_name ?? "").trimmingCharacters(in: .whitespaces)
            let label = name.isEmpty ? "unattributed" : name
            if !seen.contains(label) { seen.append(label) }
        }
        return seen
    }

    /// A placeholder word for a single item, which has no cluster to share
    /// one with. The longest surviving keyword, because the longest word in
    /// a headline is the most specific one — "countermeasures" over "list".
    /// Still only a word, never the headline.
    static func keyFor(_ item: ReviewQueueItem) -> String {
        DeskBuilder.keywords(item)
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .first ?? ""
    }

    /// A placeholder headline. Never a feed's own headline: copying one
    /// outlet's wording into the title field is how a rewrite starts.
    static func placeholderTitle(clusterKey: String) -> String {
        let k = clusterKey.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return "Untitled brief" }
        return k.prefix(1).uppercased() + k.dropFirst()
    }

    static func markdown(clusterKey: String,
                         items: [ReviewQueueItem],
                         author: String,
                         today: String) -> String {
        let title = placeholderTitle(clusterKey: clusterKey)
        let names = outlets(items)

        var out = "---\n"
        out += "title: \(FrontmatterDoc.quoteIfNeeded(title))\n"
        out += "type: brief\n"
        out += "date: \(today)\n"
        if !author.isEmpty { out += "author: \(FrontmatterDoc.quoteIfNeeded(author))\n" }
        out += "slug: \(slugify(title))\n"
        out += "description: \"\"\n"
        out += "tags: []\n"
        out += "draft: true\n"
        out += "status: draft\n"
        out += sourcesBlock(items)
        out += "---\n\n"
        out += header(names: names, count: items.count, today: today)
        out += "\n\n"
        out += ArticleTemplate.newsBrief.body
        out += "\n\n"
        out += workingNotes(items, today: today)
        out += "\n"
        return out
    }

    /// The `sources:` list in exactly the shape the site renders
    /// (`renderSources` in build-articles.js reads `url`, `title`, `tier`).
    private static func sourcesBlock(_ items: [ReviewQueueItem]) -> String {
        let usable = items.filter { !($0.source_url ?? "").isEmpty }
        guard !usable.isEmpty else { return "sources: []\n" }
        var out = "sources:\n"
        for it in usable {
            out += "  - title: \(FrontmatterDoc.quoteIfNeeded(it.displayTitle))\n"
            out += "    url: \(it.source_url ?? "")\n"
            out += "    tier: secondary\n"
        }
        return out
    }

    private static func header(names: [String], count: Int, today: String) -> String {
        let corroborated = names.count >= 2
        var out = "<div class=\"draft-note\">\n"
        out += "<p><strong>✎ Seeded from \(count) queue item\(count == 1 ? "" : "s") on \(today)"
        out += " — the app counted them, it did not read them.</strong></p>\n"
        out += "<ul>\n"
        out += "<li>The title is a placeholder built from the word these items share. Replace it.</li>\n"
        out += "<li>Every line in <em>Working notes</em> is verbatim from the feed. The app wrote no prose.</li>\n"
        if corroborated {
            out += "<li>\(names.count) independent outlets: \(names.joined(separator: ", ")).</li>\n"
        } else {
            out += "<li><strong>One outlet only (\(names.first ?? "unattributed")).</strong> "
            out += "This is a rewrite unless you add a second source, or unless the source "
            out += "is the primary document itself.</li>\n"
        }
        out += "<li>Sources are seeded <code>tier: secondary</code> — a feed item is reporting "
        out += "about a document, not the document. Promote to <code>primary</code> once you "
        out += "link the act, judgment or press release itself.</li>\n"
        out += "</ul>\n"
        out += "</div>"
        return out
    }

    private static func workingNotes(_ items: [ReviewQueueItem], today: String) -> String {
        var out = "## Working notes — raw material\n\n"
        out += "<div class=\"draft-note\">\n"
        out += "<p><strong>✎ Delete this whole section before publishing.</strong></p>\n"
        out += "</div>\n"
        for (i, it) in items.enumerated() {
            let outlet = (it.source_name ?? "").isEmpty ? "unattributed" : (it.source_name ?? "")
            var line = "\n**[\(i + 1)] \(outlet)**"
            if let pub = it.published_at, pub.count >= 10 { line += " · published \(pub.prefix(10))" }
            line += " · retrieved \(today)\n\n"
            out += line
            out += "> \(it.displayTitle)\n"
            let snip = it.displaySnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snip.isEmpty {
                /* Quoted as one block: a snippet that arrives with newlines
                   would otherwise break out of the blockquote and read as the
                   author's own text. */
                out += ">\n> " + snip.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ") + "\n"
            }
            if let url = it.source_url, !url.isEmpty { out += "\n<\(url)>\n" }
        }
        return out
    }
}
