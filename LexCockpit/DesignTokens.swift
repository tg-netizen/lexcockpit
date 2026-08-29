import Foundation
import SwiftUI

/*  DesignTokens.swift — the website's design, as values you can change
 *  ═══════════════════════════════════════════════════════════════════
 *  Every colour, spacing, radius, font and timing on lexdigestglobal.com
 *  is a custom property in assets/css/style.css. Fifty-one of them in
 *  :root, twenty-six overridden for dark mode. Everything else in that
 *  stylesheet refers to those names, so changing one value changes the
 *  whole site consistently, which is exactly what a design system is for
 *  and exactly what makes it safe to edit from an app.
 *
 *  ── Three blocks, not two ─────────────────────────────────────────────
 *  Dark mode is declared twice on purpose: once for the reader who chose
 *  it (:root[data-theme="dark"]) and once for the reader whose system is
 *  dark and who never chose anything (@media prefers-color-scheme). They
 *  have to say the same thing. Today they do, checked: twenty-six tokens
 *  each, no drift. A dark value edited here is written to both, so this
 *  app cannot be the thing that pulls them apart.
 *
 *  ── Replaced by range, never reformatted ──────────────────────────────
 *  The stylesheet is around nine thousand lines and most of it has
 *  nothing to do with tokens. So this records the exact character range
 *  of each value it read, and on save it substitutes those ranges back to
 *  front. A line that was not edited is byte for byte what it was. There
 *  is no round trip through a CSS printer that could quietly restyle the
 *  file.
 */

// MARK: - One token

struct DesignToken: Identifiable, Equatable {
    /// bg, ink, accent, status-red …
    let name: String
    var light: String
    /// nil where the token has no dark override, which is the honest
    /// state for something like a spacing value.
    var dark: String?

    /// What it was when read, so an edit can be recognised and undone.
    let originalLight: String
    let originalDark: String?

    var id: String { name }
    var isChanged: Bool { light != originalLight || dark != originalDark }

    /// Roughly what kind of value this is, for grouping and for whether a
    /// colour well makes sense next to it.
    enum Kind { case colour, length, font, timing, other }

    var kind: Kind {
        let v = light.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") || v.hasPrefix("rgb") || v.hasPrefix("hsl") { return .colour }
        if v.hasPrefix("var(") { return .other }
        if v.contains("ms") || v.contains("ease") || v.contains("cubic") { return .timing }
        if v.contains("'") || v.contains("\"") || v.contains("serif")
            || v.contains("sans") || v.contains("monospace") { return .font }
        if v.hasSuffix("rem") || v.hasSuffix("px") || v.hasSuffix("em") || v.hasSuffix("%") {
            return .length
        }
        return .other
    }

    /// The group a person would look for it in. Grouping by name and not
    /// by value type, because a reader looks for "the gold" not for
    /// "the fourth hex".
    var group: String {
        switch name {
        case "bg", "surface", "bg-blur", "bg-cream", "rule", "border-subtle",
             "border-faint", "elevate", "elevate-hover":
            return "Surfaces and lines"
        case "ink", "muted", "text-muted", "on-fill", "on-fill-muted":
            return "Ink"
        case "accent", "accent-hover", "brand-navy", "navy-accent",
             "highlight", "gold-text", "gold-token":
            return "Accent and gold"
        case let n where n.hasPrefix("status") || n == "danger" || n == "danger-dark"
            || n.hasPrefix("warn"):
            return "Status"
        case let n where n.hasPrefix("map") || n == "dfn-grid":
            return "Maps"
        case "serif", "sans", "mono", "tracking-meta":
            return "Type"
        case "space-section", "rhythm", "measure", "measure-lead", "measure-mono",
             "max-w", "radius-card":
            return "Layout and rhythm"
        case "ease-ui":
            return "Motion"
        default:
            return "Other"
        }
    }

    static let groupOrder = ["Surfaces and lines", "Ink", "Accent and gold", "Status",
                             "Type", "Layout and rhythm", "Motion", "Maps", "Other"]
}

// MARK: - The stylesheet

/// The three token blocks of style.css, with the ranges to write back into.
struct DesignSheet {
    /// The whole file, unchanged.
    private let source: String
    /// Value ranges per token: one in the light block, up to two in dark.
    private var lightRanges: [String: NSRange] = [:]
    private var darkRanges: [String: [NSRange]] = [:]

    var tokens: [DesignToken]
    var sha: String?
    let path = "assets/css/style.css"

    /// How much of the file the parse actually accounted for, so the panel
    /// can say what it is based on instead of implying it read everything.
    let blocksFound: Int

    // MARK: Reading

    init(css: String, sha: String?) throws {
        self.source = css
        self.sha = sha

        let ns = css as NSString
        /* The three selectors, in the order they appear. The dark ones are
           matched on their exact opening text so a rule that merely
           mentions them further down cannot be mistaken for the block. */
        let selectors = [
            ":root {",
            ":root[data-theme=\"dark\"] {",
            ":root:not([data-theme=\"light\"]) {"
        ]
        var blocks: [(sel: Int, range: NSRange)] = []
        for (i, sel) in selectors.enumerated() {
            let r = ns.range(of: sel)
            guard r.location != NSNotFound else { continue }
            guard let body = Self.braceBody(ns, openBraceAt: r.location + r.length - 1)
            else { continue }
            blocks.append((i, body))
        }
        blocksFound = blocks.count
        guard blocks.contains(where: { $0.sel == 0 }) else {
            throw NSError(domain: "DesignSheet", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No :root block found in style.css, so there is nothing to read."])
        }

        let decl = try NSRegularExpression(pattern: #"--([a-z0-9-]+)\s*:\s*([^;]+);"#)
        var light: [String: String] = [:]
        var dark: [String: String] = [:]

        /* Collected into locals first. Swift will not let a closure touch
           a stored property before every one of them is initialised, and
           tokens is assigned last. */
        var lr: [String: NSRange] = [:]
        var dr: [String: [NSRange]] = [:]

        for b in blocks {
            decl.enumerateMatches(in: css, range: b.range) { m, _, _ in
                guard let m, m.numberOfRanges > 2 else { return }
                let name = ns.substring(with: m.range(at: 1))
                let vRange = m.range(at: 2)
                let value = ns.substring(with: vRange).trimmingCharacters(in: .whitespaces)
                if b.sel == 0 {
                    light[name] = value
                    lr[name] = vRange
                } else {
                    dark[name] = value
                    dr[name, default: []].append(vRange)
                }
            }
        }

        self.lightRanges = lr
        self.darkRanges = dr
        self.tokens = light.keys.sorted().map { n in
            DesignToken(name: n, light: light[n] ?? "", dark: dark[n],
                        originalLight: light[n] ?? "", originalDark: dark[n])
        }
    }

    /// The range between a brace and its match, exclusive.
    private static func braceBody(_ ns: NSString, openBraceAt i: Int) -> NSRange? {
        var depth = 0
        var j = i
        while j < ns.length {
            let c = ns.character(at: j)
            if c == 123 { depth += 1 }              // {
            if c == 125 {                            // }
                depth -= 1
                if depth == 0 { return NSRange(location: i + 1, length: j - i - 1) }
            }
            j += 1
        }
        return nil
    }

    // MARK: Writing

    var changed: [DesignToken] { tokens.filter(\.isChanged) }

    /// The file with the edited values substituted in, and nothing else
    /// touched. Substitutions run back to front so earlier offsets stay
    /// valid while later ones are replaced.
    func rendered() -> String {
        var edits: [(NSRange, String)] = []
        for t in changed {
            if t.light != t.originalLight, let r = lightRanges[t.name] {
                edits.append((r, t.light))
            }
            if t.dark != t.originalDark, let d = t.dark {
                /* Both dark blocks, always. Writing one and not the other
                   is how a stylesheet starts disagreeing with itself. */
                for r in darkRanges[t.name] ?? [] { edits.append((r, d)) }
            }
        }
        guard !edits.isEmpty else { return source }
        let out = NSMutableString(string: source)
        for (r, v) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: r, with: v)
        }
        return out as String
    }

    /// True where a dark value exists but only one of the two dark blocks
    /// carries it. Nothing in this app creates that, but the stylesheet is
    /// also edited by hand, so it is worth saying out loud.
    var darkOutOfSync: [String] {
        tokens.compactMap { t in
            guard t.dark != nil else { return nil }
            return (darkRanges[t.name]?.count ?? 0) < 2 ? t.name : nil
        }
    }
}

// MARK: - Colour arithmetic, for telling the truth about contrast

enum CSSColour {
    /// #RGB, #RRGGBB and rgb/rgba(). Anything else, including var(), is
    /// nil rather than a guess.
    static func parse(_ s: String, in tokens: [DesignToken],
                      dark: Bool, depth: Int = 0) -> (r: Double, g: Double, b: Double)? {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("var(") && depth < 4 {
            /* One name deep is normal here: --bg-cream is var(--bg). */
            let inner = v.dropFirst(4).prefix(while: { $0 != ")" })
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "--", with: "")
            guard let t = tokens.first(where: { $0.name == inner }) else { return nil }
            return parse(dark ? (t.dark ?? t.light) : t.light,
                         in: tokens, dark: dark, depth: depth + 1)
        }
        if v.hasPrefix("#") {
            var h = String(v.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let n = UInt32(h, radix: 16) else { return nil }
            return (Double((n >> 16) & 0xFF) / 255,
                    Double((n >> 8) & 0xFF) / 255,
                    Double(n & 0xFF) / 255)
        }
        if v.hasPrefix("rgb") {
            let nums = v.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                .split(separator: ",").compactMap {
                    Double($0.trimmingCharacters(in: .whitespaces))
                }
            guard nums.count >= 3 else { return nil }
            return (nums[0] / 255, nums[1] / 255, nums[2] / 255)
        }
        return nil
    }

    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func f(_ x: Double) -> Double {
            x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }

    /// WCAG 2.1 contrast ratio, or nil where either colour is not a plain
    /// colour. A missing number is said as missing, never as 1.0.
    static func contrast(_ a: String, _ b: String,
                         in tokens: [DesignToken], dark: Bool) -> Double? {
        guard let ca = parse(a, in: tokens, dark: dark, depth: 0),
              let cb = parse(b, in: tokens, dark: dark, depth: 0) else { return nil }
        let la = luminance(ca), lb = luminance(cb)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func swatch(_ s: String, in tokens: [DesignToken], dark: Bool) -> Color? {
        guard let c = parse(s, in: tokens, dark: dark, depth: 0) else { return nil }
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// A pair the site actually puts together, so the number means something.
struct ContrastPair: Identifiable {
    let label: String
    let fg: String
    let bg: String
    /// Body text needs 4.5. Large text and non-text need 3.
    let needs: Double
    var id: String { label }

    static let all: [ContrastPair] = [
        .init(label: "Body text on the page",   fg: "ink",   bg: "bg",      needs: 4.5),
        .init(label: "Body text on a card",     fg: "ink",   bg: "surface", needs: 4.5),
        .init(label: "Muted text on a card",    fg: "muted", bg: "surface", needs: 4.5),
        .init(label: "Links on a card",         fg: "accent", bg: "surface", needs: 4.5),
        .init(label: "Gold text on a card",     fg: "gold-text", bg: "surface", needs: 4.5),
        .init(label: "Green status text",       fg: "status-green-text", bg: "surface", needs: 4.5),
        .init(label: "Amber status text",       fg: "status-amber-text", bg: "surface", needs: 4.5),
        .init(label: "Red status text",         fg: "status-red-text", bg: "surface", needs: 4.5),
        .init(label: "Hairline against a card", fg: "rule",  bg: "surface", needs: 1.1),
        .init(label: "A card against the page", fg: "surface", bg: "bg",    needs: 1.05)
    ]
}
