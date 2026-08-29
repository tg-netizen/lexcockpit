import Foundation

/*  BlockRenderer.swift — dieselben Bloecke, dasselbe HTML
 *  ═══════════════════════════════════════════════════════════════════
 *  Die Vorschau muss zeigen, was der Deploy bauen wird, sonst ist sie
 *  schlimmer als keine: sie beruhigt, ohne zu stimmen. Auf der Website
 *  rendert scripts/build-pages.js die Bloecke, hier tut es Swift, und
 *  zwei Renderer, die auseinanderdriften, sind eine Fehlerquelle mit
 *  Ansage.
 *
 *  Dagegen gibt es --rendercheck. Der Modus nimmt das echte Repo, rendert
 *  jede Seite aus data/pages hier in Swift und vergleicht Zeichen fuer
 *  Zeichen mit dem, was der Node-Generator in die Seite geschrieben hat.
 *  Solange das durchlaeuft, ist die Vorschau nicht aehnlich, sondern
 *  gleich. Weicht es ab, faellt es beim naechsten Selbsttest auf und
 *  nicht beim naechsten Leser.
 *
 *  Jede Aenderung hier gehoert also in build-pages.js gespiegelt und
 *  umgekehrt. Das ist laestig und billiger als eine Vorschau, der man
 *  nicht glauben kann.
 */

enum BlockRenderer {

    // MARK: Maskierung, wie im Generator

    /// Fuer Attributwerte.
    static func esc(_ s: String?) -> String {
        (s ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Fuer Fliesstext: jede wohlgeformte Entitaet und die Inline-Tags,
    /// die im Bestand vorkommen, bleiben stehen. Alles andere wird
    /// entschaerft. Wortgleich mit rich() in build-pages.js.
    static func rich(_ s: String?) -> String {
        var out = s ?? ""
        out = replace(out,
            pattern: "&(?!(#\\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]{1,31});)",
            with: "&amp;")
        out = replace(out,
            pattern: "<(?!/?(a|em|strong|abbr|code|sup|sub|br|span|b|i|q|cite|time)\\b)",
            with: "&lt;")
        return out
    }

    private static func replace(_ s: String, pattern: String, with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s,
                                           range: NSRange(location: 0, length: ns.length),
                                           withTemplate: with)
    }

    private static func ind(_ n: Int) -> String { String(repeating: " ", count: n) }

    // MARK: Ein Block

    static func block(_ b: PageBlock, pad: Int) -> String {
        let p = ind(pad)
        let f = b.fields
        func str(_ k: String) -> String? { f[k]?.stringValue }
        func list(_ k: String) -> [String] { f[k]?.stringList ?? [] }

        switch b.type {
        case "lead":
            return p + "<p class=\"dd-lead\">" + rich(str("text")) + "</p>"
        case "prose":
            return p + "<p>" + rich(str("text")) + "</p>"
        case "subhead":
            return p + "<p class=\"dd-lead dd-lead--spaced\">" + rich(str("text")) + "</p>"
        case "limit":
            return p + "<p class=\"ai-limit\">" + rich(str("text")) + "</p>"
        case "hint":
            return p + "<p class=\"ai-hint\">" + rich(str("text")) + "</p>"
        case "next":
            return p + "<p class=\"dd-next\"><a href=\"" + esc(str("href")) + "\">"
                 + rich(str("label")) + " &rarr;</a></p>"
        case "counts":
            return p + "<p class=\"dd-counts\">"
                 + list("items").map { "<span>" + rich($0) + "</span>" }.joined()
                 + "</p>"

        case "image":
            let w = str("width") ?? number(f["width"])
            let h = str("height") ?? number(f["height"])
            var out = p + "<figure class=\"fig\">\n"
                + p + "  <img src=\"" + esc(str("src")) + "\" alt=\"" + esc(str("alt") ?? "") + "\""
                + (w.isEmpty ? "" : " width=\"" + esc(w) + "\"")
                + (h.isEmpty ? "" : " height=\"" + esc(h) + "\"")
                + " loading=\"lazy\">\n"
            if let c = str("caption"), !c.isEmpty {
                out += p + "  <figcaption>" + rich(c) + "</figcaption>\n"
            }
            if let c = str("credit"), !c.isEmpty {
                out += p + "  <p class=\"fig__credit\">" + rich(c) + "</p>\n"
            }
            return out + p + "</figure>"

        case "gaps":
            let items = list("items").map { p + "    <li>" + rich($0) + "</li>" }
                .joined(separator: "\n")
            let heading = (str("heading")?.isEmpty == false) ? str("heading") : "What is not known"
            return p + "<div class=\"dd-gaps\">\n"
                + p + "  <p class=\"dd-gaps__h\">" + rich(heading) + "</p>\n"
                + p + "  <ul>\n" + items + "\n" + p + "  </ul>\n"
                + p + "</div>"

        case "table":
            let head = list("columns").map { "<th scope=\"col\">" + rich($0) + "</th>" }.joined()
            let body = (f["rows"]?.arrayValue ?? []).map { row -> String in
                p + "      <tr>" + (row.arrayValue ?? [])
                    .map { "<td>" + rich($0.stringValue ?? "") + "</td>" }.joined() + "</tr>"
            }.joined(separator: "\n")
            var out = p + "<div class=\"dd-tablewrap\">\n"
                + p + "  <table class=\"dd-table\">\n"
                + p + "    <thead><tr>" + head + "</tr></thead>\n"
                + p + "    <tbody>\n" + body + "\n" + p + "    </tbody>\n"
                + p + "  </table>\n"
                + p + "</div>"
            if let n = str("note"), !n.isEmpty {
                out += "\n" + p + "<p class=\"ai-limit\">" + rich(n) + "</p>"
            }
            return out

        case "sources":
            let items = (f["items"]?.arrayValue ?? []).map { it -> String in
                let o = it.objectValue ?? [:]
                let url = o["url"]?.stringValue ?? ""
                let title = o["title"]?.stringValue ?? url
                return p + "    <li><a href=\"" + esc(url) + "\" rel=\"noopener\">"
                     + rich(title) + "</a></li>"
            }.joined(separator: "\n")
            let notes: [String] = {
                if let n = f["notes"]?.stringList, !n.isEmpty { return n }
                if let n = str("note"), !n.isEmpty { return [n] }
                return []
            }()
            let summary = (str("summary")?.isEmpty == false) ? str("summary") : "Sources and method"
            var out = p + "<details class=\"dd-srcs\">\n"
                + p + "  <summary>" + rich(summary) + "</summary>\n"
            out += notes.map { p + "  <p class=\"dd-src\">" + rich($0) + "</p>\n" }.joined()
            if !items.isEmpty { out += p + "  <ul>\n" + items + "\n" + p + "  </ul>\n" }
            return out + p + "</details>"

        case "tool":
            let params = f["params"]?.objectValue ?? [:]
            let attrs = params.keys.sorted().map { k -> String in
                " " + (k.hasPrefix("data-") ? k : "data-" + k)
                    + "=\"" + esc(params[k]?.stringValue ?? number(params[k])) + "\""
            }.joined()
            return p + "<div class=\"" + esc(str("cls") ?? "") + "\" "
                 + esc(str("attribute")) + attrs + "></div>"

        case "html":
            return str("raw") ?? ""

        default:
            return ""
        }
    }

    private static func number(_ v: JSONValue?) -> String {
        guard case .number(let d) = v else { return "" }
        return d == d.rounded() ? String(Int(d)) : String(d)
    }

    // MARK: Ein Abschnitt, eine Seite

    static func section(_ s: PageSection, index: Int) -> String {
        let id = s.sectionID.isEmpty ? "s\(index + 1)" : s.sectionID
        let pad = 4
        let p = ind(pad)
        var out = p + "<section class=\"dd-section\" aria-labelledby=\"" + esc(id) + "-h\">\n"
        if !s.eyebrow.isEmpty {
            out += p + "  <p class=\"dd-eyebrow\">"
                + s.eyebrow.map { "<span>" + rich($0) + "</span>" }.joined()
                + "</p>\n"
        }
        if !s.heading.isEmpty {
            out += p + "  <h2 class=\"dd-h\" id=\"" + esc(id) + "-h\">"
                + rich(s.heading) + "</h2>\n"
        }
        out += s.blocks.map { block($0, pad: pad + 2) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return out + "\n" + p + "</section>"
    }

    /// Der Rumpf einer Seite, genau so wie build-pages.js ihn zwischen die
    /// Marker schreibt.
    static func body(_ page: SitePage) -> String {
        page.sections.enumerated()
            .map { section($1, index: $0) }
            .joined(separator: "\n\n")
    }
}
