import Foundation

/// Frontmatter handling built for round-trip safety.
///
/// Design: the YAML block is split into ordered entries, each keeping its
/// ORIGINAL raw lines. The editor form binds only simple one-line scalars
/// (and block lists for `tags`). On save, an entry is re-serialized ONLY if
/// the form actually changed it — every untouched entry (including unknown
/// keys, multi-line values, comments, odd syntax) is written back verbatim.
/// A file opened and saved without edits round-trips byte-identically.
struct FMEntry {
    var key: String?             // nil = leading raw block (comments etc.)
    var rawLines: [String]       // verbatim original lines
    var value: String?           // parsed scalar (only for simple one-liners)
    var listItems: [String]?     // parsed list (block or inline)
    var inlineList = false       // `tags: [a, b]` style
    var edited = false           // form changed it → re-serialize on save

    var isSimpleScalar: Bool { rawLines.count == 1 && value != nil }
    var isBindableList: Bool { listItems != nil }
}

struct FrontmatterDoc {
    var entries: [FMEntry] = []
    var body: String = ""
    var hadFrontmatter = false

    // MARK: Parse

    static func parse(_ text: String) -> FrontmatterDoc {
        var doc = FrontmatterDoc()
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1, lines[0] == "---" || lines[0] == "---\r" else {
            doc.body = text
            return doc
        }
        var closeIdx: Int? = nil
        for i in 1..<lines.count where lines[i] == "---" || lines[i] == "---\r" {
            closeIdx = i
            break
        }
        guard let close = closeIdx else {
            doc.body = text
            return doc
        }
        doc.hadFrontmatter = true
        doc.body = lines[(close + 1)...].joined(separator: "\n")
        doc.entries = groupEntries(Array(lines[1..<close]))
        return doc
    }

    private static func groupEntries(_ fmLines: [String]) -> [FMEntry] {
        var entries: [FMEntry] = []
        var current: FMEntry? = nil

        func flush() {
            guard var e = current else { return }
            e = classify(e)
            entries.append(e)
            current = nil
        }

        for line in fmLines {
            if let (key, rest) = keyLine(line) {
                flush()
                current = FMEntry(key: key, rawLines: [line], value: rest.isEmpty ? nil : rest)
            } else if current != nil {
                current!.rawLines.append(line)
            } else {
                // leading lines before any key (comments/blank) — opaque block
                if entries.isEmpty || entries[entries.count - 1].key != nil {
                    entries.append(FMEntry(key: nil, rawLines: [line]))
                } else {
                    entries[entries.count - 1].rawLines.append(line)
                }
            }
        }
        flush()
        return entries
    }

    /// `key: rest` at column 0 → (key, trimmed rest); anything else nil.
    private static func keyLine(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        guard !key.isEmpty,
              key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    /// Decide what an entry is once all its lines are collected.
    private static func classify(_ e: FMEntry) -> FMEntry {
        var entry = e
        let rest = entry.value ?? ""

        if entry.rawLines.count == 1 {
            if rest.isEmpty {
                entry.value = nil                       // `key:` alone — opaque
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                entry.value = nil                       // block scalar — opaque
            } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                // inline list `[a, b]`
                let inner = String(rest.dropFirst().dropLast())
                entry.listItems = inner.isEmpty ? [] :
                    inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
                entry.inlineList = true
                entry.value = nil
            } else {
                entry.value = unquote(rest)             // simple scalar
            }
            return entry
        }

        // Multi-line: bindable only if `key:` + pure `- item` block list.
        entry.value = nil
        if rest.isEmpty {
            var items: [String] = []
            var pure = true
            for line in entry.rawLines.dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { pure = false; break }
                guard t.hasPrefix("- ") || t == "-" else { pure = false; break }
                items.append(unquote(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            }
            if pure { entry.listItems = items }
        }
        return entry
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: Query / mutate (used by the editor form)

    func scalar(_ key: String) -> String? {
        entries.first(where: { $0.key == key })?.value
    }

    func list(_ key: String) -> [String]? {
        entries.first(where: { $0.key == key })?.listItems
    }

    /// True when the key exists but in a shape the form must not touch.
    func isOpaque(_ key: String) -> Bool {
        guard let e = entries.first(where: { $0.key == key }) else { return false }
        return !e.isSimpleScalar && !e.isBindableList
    }

    /// Set a scalar; appends the key if missing. Marks the entry edited only
    /// when the value really changed (preserving byte-perfect round-trips).
    mutating func setScalar(_ key: String, _ newValue: String) {
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            guard entries[idx].isSimpleScalar || entries[idx].rawLines.count == 1 else { return } // opaque — refuse
            if entries[idx].value == newValue { return }
            entries[idx].value = newValue
            entries[idx].edited = true
        } else {
            guard !newValue.isEmpty else { return }
            entries.append(FMEntry(key: key, rawLines: [], value: newValue, edited: true))
        }
    }

    mutating func setList(_ key: String, _ items: [String]) {
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            guard entries[idx].isBindableList else { return }                  // opaque — refuse
            if entries[idx].listItems == items { return }
            entries[idx].listItems = items
            entries[idx].edited = true
        } else {
            var e = FMEntry(key: key, rawLines: [], value: nil, edited: true)
            e.listItems = items
            entries.append(e)
        }
    }

    // MARK: Serialize

    func serialize() -> String {
        if !hadFrontmatter && entries.isEmpty { return body }
        var out = "---\n"
        for e in entries {
            if !e.edited {
                out += e.rawLines.joined(separator: "\n") + "\n"
            } else if let items = e.listItems {
                let key = e.key ?? ""
                if e.inlineList || items.isEmpty {
                    out += "\(key): [\(items.map(Self.quoteIfNeeded).joined(separator: ", "))]\n"
                } else {
                    out += "\(key):\n"
                    for item in items { out += "  - \(Self.quoteIfNeeded(item))\n" }
                }
            } else {
                out += "\(e.key ?? ""): \(Self.quoteIfNeeded(e.value ?? ""))\n"
            }
        }
        out += "---\n"
        out += body
        return out
    }

    static func quoteIfNeeded(_ v: String) -> String {
        if v.isEmpty { return "\"\"" }
        if v == "true" || v == "false" { return v }
        let needsQuotes = v.contains(": ") || v.hasSuffix(":") || v.contains(" #")
            || v.hasPrefix("#") || v.hasPrefix("- ") || v.hasPrefix("[") || v.hasPrefix("{")
            || v.hasPrefix("'") || v.hasPrefix("\"") || v.hasPrefix("*") || v.hasPrefix("&")
            || v.hasPrefix("!") || v.hasPrefix("|") || v.hasPrefix(">") || v.hasPrefix("%")
            || v.hasPrefix("@") || v != v.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return v }
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Slug

/// Lowercased, umlauts transliterated (ä→ae ö→oe ü→ue ß→ss), other diacritics
/// stripped, everything else hyphenated.
func slugify(_ title: String) -> String {
    var s = title.lowercased()
    for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"),
                       ("æ", "ae"), ("ø", "oe"), ("å", "aa")] {
        s = s.replacingOccurrences(of: from, with: to)
    }
    s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
    let mapped = s.map { ch -> String in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) ? String(ch) : "-"
    }.joined()
    let collapsed = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// Frontmatter template for a brand-new article (draft by default; `status`
/// matches what the site's build scripts read, `draft` what the app toggles).
func newArticleTemplate(title: String, author: String) -> String {
    let slug = slugify(title)
    var out = "---\n"
    out += "title: \(FrontmatterDoc.quoteIfNeeded(title))\n"
    out += "date: \(todayISO())\n"
    if !author.isEmpty { out += "author: \(FrontmatterDoc.quoteIfNeeded(author))\n" }
    out += "slug: \(slug)\n"
    out += "description: \"\"\n"
    out += "tags: []\n"
    out += "draft: true\n"
    out += "status: draft\n"
    out += "---\n\n"
    return out
}

// MARK: - Self-test (run with `swift run LexCockpit --selftest`)

func runFrontmatterSelfTests() -> Bool {
    var ok = true
    func expect(_ cond: Bool, _ name: String) {
        print(cond ? "PASS  \(name)" : "FAIL  \(name)")
        if !cond { ok = false }
    }

    // 1. Byte-perfect round-trip with unknown keys, quoted scalars, lists.
    let sample = """
    ---
    title: Vienna's Rent Secret
    type: deep-dive
    date: 2026-06-18
    tldr: 'Why does Vienna remain affordable: a hundred-year experiment'
    hero_image: /assets/articles/Vianna living.jpg
    tags:
      - Vienna
      - housing
    status: published
    allow_placeholder_publish: true
    sources: []
    ---

    Body text stays **exactly** as written.

    Even trailing spaces and gaps.
    """
    let doc = FrontmatterDoc.parse(sample)
    expect(doc.serialize() == sample, "untouched file round-trips byte-identically")
    expect(doc.scalar("title") == "Vienna's Rent Secret", "parses title")
    expect(doc.list("tags") == ["Vienna", "housing"], "parses block-list tags")
    expect(doc.scalar("status") == "published", "parses status")

    // 2. Editing a known key keeps every unknown line verbatim.
    var doc2 = FrontmatterDoc.parse(sample)
    doc2.setScalar("title", "New Title: With Colon")
    let out2 = doc2.serialize()
    expect(out2.contains("title: \"New Title: With Colon\""), "edited title re-serialized quoted")
    expect(out2.contains("tldr: 'Why does Vienna remain affordable: a hundred-year experiment'"),
           "unknown tldr line untouched")
    expect(out2.contains("hero_image: /assets/articles/Vianna living.jpg"), "unknown hero_image untouched")
    expect(out2.contains("allow_placeholder_publish: true"), "unknown bool untouched")
    expect(out2.contains("sources: []"), "unknown empty list untouched")
    expect(out2.contains("Body text stays **exactly** as written."), "body preserved")

    // 3. Draft toggle via status + draft.
    var doc3 = FrontmatterDoc.parse(sample)
    doc3.setScalar("status", "draft")
    expect(doc3.serialize().contains("status: draft"), "status flip serializes")

    // 4. Slugs with umlaut transliteration.
    expect(slugify("Über die Straße & Bäume") == "ueber-die-strasse-baeume", "umlaut slug ä→ae ü→ue ß→ss")
    expect(slugify("Hello,  World! 2026") == "hello-world-2026", "punctuation collapses to hyphens")

    // 5. File without frontmatter stays untouched.
    let plain = "# Just markdown\n\nNo frontmatter here.\n"
    expect(FrontmatterDoc.parse(plain).serialize() == plain, "no-frontmatter file round-trips")

    // 6. New-article template.
    let tpl = newArticleTemplate(title: "Mein Länder-Überblick", author: "Theo Glunz")
    expect(tpl.contains("draft: true") && tpl.contains("status: draft"), "template is a draft")
    expect(tpl.contains("slug: mein-laender-ueberblick"), "template slug transliterated")

    return ok
}
