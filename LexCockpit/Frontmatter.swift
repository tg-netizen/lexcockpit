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

    /// Remove an entry entirely (e.g. clearing scheduled_publish_at).
    mutating func removeEntry(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    /// Replace (or append) an entry as verbatim raw lines — used for
    /// structured metadata blocks the form never shows (e.g. canva_designs).
    mutating func setRawLines(_ key: String, _ lines: [String]) {
        var entry = FMEntry(key: key, rawLines: lines, value: nil)
        entry.edited = false          // serialize() emits rawLines verbatim
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        hadFrontmatter = true
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
/// Article templates for the new-article gallery (Canva-style start):
/// each gives a pre-structured body so nobody faces an empty page.
enum ArticleTemplate: String, CaseIterable, Identifiable {
    case blank, deepDive, newsBrief, trackerUpdate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank:         return "Blank"
        case .deepDive:      return "Deep dive"
        case .newsBrief:     return "News brief"
        case .trackerUpdate: return "Tracker update"
        }
    }

    var desc: String {
        switch self {
        case .blank:         return "Empty page, no structure"
        case .deepDive:      return "Long-form: hook, history, key facts, analysis"
        case .newsBrief:     return "Short: what happened, why it matters, what's next"
        case .trackerUpdate: return "Regulation change: what moved, old → new, deadlines"
        }
    }

    var icon: String {
        switch self {
        case .blank:         return "doc"
        case .deepDive:      return "text.book.closed"
        case .newsBrief:     return "bolt"
        case .trackerUpdate: return "antenna.radiowaves.left.and.right"
        }
    }

    var typeValue: String? {
        switch self {
        case .blank: return nil
        case .deepDive: return "deep-dive"
        case .newsBrief: return "brief"
        case .trackerUpdate: return "tracker-update"
        }
    }

    var body: String {
        switch self {
        case .blank:
            return ""
        case .deepDive:
            // Feature dramaturgy (researched: lede → nut graf → thesis/
            // antithesis/synthesis → kicker). Schema notes guide each
            // section and are stripped automatically on publish.
            return """
            <div class="draft-note">
            <p><strong>✎ Schema — Lede (the opening)</strong></p>
            <ul>
            <li>Open with ONE concrete scene, person or moment — no abstractions</li>
            <li>3–5 sentences; the reader should FEEL the question before you name it</li>
            <li>Good types: scene, anecdote, striking contrast, surprising number</li>
            </ul>
            </div>

            Write the opening scene here.

            <div class="draft-note">
            <p><strong>✎ Schema — Nut graf (why this, why now)</strong></p>
            <ul>
            <li>ONE paragraph: what this story is about, why it matters, why today</li>
            <li>Name the stakes and who is affected — this is the article's anchor</li>
            </ul>
            </div>

            State the nut graf here.

            ## The backstory

            <div class="draft-note">
            <p><strong>✎ Schema — Context</strong></p>
            <ul>
            <li>How did we get here? 2–3 paragraphs of history the reader needs</li>
            <li>Every claim gets a number, a date or a source</li>
            </ul>
            </div>

            Write the context here.

            ## The case

            <div class="draft-note">
            <p><strong>✎ Schema — Thesis</strong></p>
            <ul>
            <li>The strongest version of the main argument, with evidence</li>
            <li>Add a voice: one real quote (blockquote with attribution)</li>
            <li>Lift the single best sentence into a pull-quote (+ → Pull quote)</li>
            </ul>
            </div>

            Argue the case here.

            ## The counter

            <div class="draft-note">
            <p><strong>✎ Schema — Antithesis</strong></p>
            <ul>
            <li>Take the opposing view seriously: who disagrees, and why</li>
            <li>Steelman it — the piece gets stronger, not weaker</li>
            <li>📷 Good spot for a figure or data graphic (+ → Figure)</li>
            </ul>
            </div>

            Present the counter-arguments here.

            ## What it means

            <div class="draft-note">
            <p><strong>✎ Schema — Synthesis</strong></p>
            <ul>
            <li>Your analysis: what follows from thesis vs. antithesis</li>
            <li>Move from the personal to the universal and back</li>
            <li>Summarise the hard numbers in a Key-facts box (+ → Key facts)</li>
            </ul>
            </div>

            Write the synthesis here.

            ---

            ## The takeaway

            <div class="draft-note">
            <p><strong>✎ Schema — Kicker (the ending)</strong></p>
            <ul>
            <li>Circle back to the opening scene, OR end on a strong quote, OR leave one sharp question</li>
            <li>No new facts here — the last sentence should echo</li>
            </ul>
            </div>

            Write the kicker here.
            """
        case .newsBrief:
            // Inverted pyramid: most important first, context after, outlook last.
            return """
            <div class="draft-note">
            <p><strong>✎ Schema — Lead (inverted pyramid)</strong></p>
            <ul>
            <li>First 2 sentences answer: who, what, when, where, why</li>
            <li>No warm-up — the most important fact comes first</li>
            </ul>
            </div>

            **What happened:** one paragraph, just the facts.

            **Why it matters:** one paragraph — who is affected and how.

            <div class="callout callout--info">
            <p>Good to know: one piece of context most coverage misses.</p>
            </div>

            **What's next:** dates, deadlines, the thing to watch.

            <div class="draft-note">
            <p><strong>✎ Schema — Check before publishing</strong></p>
            <ul>
            <li>Can the reader act on this in under 2 minutes of reading?</li>
            <li>Is every date and number sourced?</li>
            </ul>
            </div>
            """
        case .trackerUpdate:
            return """
            ## What moved

            <div class="draft-note">
            <p><strong>✎ Schema</strong></p>
            <ul>
            <li>Which regulation changed, when, and in which official source</li>
            <li>Link the CELEX / Official Journal reference</li>
            </ul>
            </div>

            Which regulation changed, and when.

            <div class="callout callout--warn">
            <p>Watch out: the change that affects readers directly.</p>
            </div>

            ## Old → new

            <div class="draft-note">
            <p><strong>✎ Schema</strong></p>
            <ul>
            <li>Quote the old wording, then the new wording — verbatim</li>
            <li>One sentence per change on what it means in practice</li>
            </ul>
            </div>

            What the text said before, what it says now.

            <div class="keyfacts">
            <p><strong>Deadlines</strong></p>
            <ul>
            <li>Date — obligation</li>
            </ul>
            </div>

            ## Our read

            What this means in practice.
            """
        }
    }
}

func newArticleTemplate(title: String, author: String,
                        template: ArticleTemplate = .blank) -> String {
    let slug = slugify(title)
    var out = "---\n"
    out += "title: \(FrontmatterDoc.quoteIfNeeded(title))\n"
    if let type = template.typeValue { out += "type: \(type)\n" }
    out += "date: \(todayISO())\n"
    if !author.isEmpty { out += "author: \(FrontmatterDoc.quoteIfNeeded(author))\n" }
    out += "slug: \(slug)\n"
    out += "description: \"\"\n"
    out += "tags: []\n"
    out += "draft: true\n"
    out += "status: draft\n"
    out += "---\n\n"
    let body = template.body
    if !body.isEmpty { out += body + "\n" }
    return out
}

// MARK: - Self-test (run with `swift run LexCockpit --selftest`)

func runFrontmatterSelfTests() -> (ok: Bool, passed: Int) {
    var ok = true
    var passed = 0
    func expect(_ cond: Bool, _ name: String) {
        print(cond ? "PASS  \(name)" : "FAIL  \(name)")
        if cond { passed += 1 } else { ok = false }
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

    // 6a. AI ingest frontmatter flags (written by supabase/pipeline workers).
    let aiSample = """
    ---
    title: Sanctions briefing
    date: 2026-08-08
    draft: true
    status: draft
    origin: ai-ingest
    ai_generated: true
    review_required: true
    source_url: https://example.com/story
    ---

    Body.
    """
    let aiDoc = FrontmatterDoc.parse(aiSample)
    expect(aiDoc.scalar("ai_generated") == "true"
           && aiDoc.scalar("origin") == "ai-ingest"
           && aiDoc.scalar("review_required") == "true",
           "parses AI ingest frontmatter flags")

    // 6b. Entry removal keeps everything else verbatim.
    var docR = FrontmatterDoc.parse(sample)
    docR.setScalar("scheduled_publish_at", "2026-08-01")
    docR.removeEntry("scheduled_publish_at")
    expect(!docR.serialize().contains("scheduled_publish_at")
           && docR.serialize().contains("hero_image: /assets/articles/Vianna living.jpg"),
           "removeEntry drops only the target key")

    // 7. PKCE S256 — RFC 7636 Appendix B reference vector.
    expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
           == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE S256 matches RFC 7636 vector")
    let v = PKCE.makeVerifier()
    expect(v.count >= 43 && v.count <= 128, "PKCE verifier length in RFC bounds")
    expect(!v.contains("+") && !v.contains("/") && !v.contains("="), "PKCE verifier is base64url")

    // 8b. Canva authorize URL — exactly the five enabled scopes, %3A/%20 encoded.
    let authURL = CanvaAuth.authorizeURL(clientID: "cid", challenge: "chal", state: "st").absoluteString
    expect(authURL.contains("scope=asset%3Aread%20asset%3Awrite%20design%3Acontent%3Aread%20design%3Acontent%3Awrite%20design%3Ameta%3Aread"),
           "authorize URL has the five scopes, %3A/%20 encoded")
    expect(!authURL.contains("profile") && !authURL.contains("+"),
           "authorize URL has no extra scopes and no '+' encoding")

    // 8. OAuth callback request-line parsing (incl. percent-decoding + state).
    let q = OAuthLoopback.queryItems(fromRequestLine: "GET /callback?code=abc%2F123&state=xyz HTTP/1.1\r\nHost: x")
    expect(q["code"] == "abc/123" && q["state"] == "xyz", "loopback parses code + state")

    // 9. Design-block detection (feeds the vault: Toast's WYSIWYG cannot
    //    round-trip raw HTML containers, so they are vaulted before loading).
    expect(WysiwygController.hasDesignBlocks("x\n<div class=\"pull-quote\">q</div>"),
           "detects pull-quote block")
    expect(WysiwygController.hasDesignBlocks("<div class=\"callout callout--info\">i</div>"),
           "detects callout block")
    expect(WysiwygController.hasDesignBlocks("<div class=\"keyfacts\">f</div>")
           && WysiwygController.hasDesignBlocks("<figure><img src=\"x\"></figure>"),
           "detects keyfacts + figure blocks")
    expect(!WysiwygController.hasDesignBlocks("Plain **markdown** with > quote\n\n---\n\n## h2"),
           "plain markdown is not flagged as blocks")

    // 10. Block vault — the data-safety engine behind the one-canvas editor.
    let vaultBody = """
    Intro paragraph.

    <div class="pull-quote">Single line quote.</div>

    ## Heading

    <div class="callout callout--info">
    <p>Multi
    line inner.</p>
    </div>

    > "Quoted text."
    >
    > — Attribution

    <figure>
    <img src="/assets/x.png" alt="">
    <figcaption>Cap.</figcaption>
    </figure>

    End.
    """
    let peeled = BlockVault.peel(vaultBody)
    expect(peeled.vault.count == 3, "vault captures all three raw blocks")
    expect(!peeled.display.contains("\n<p>Multi"),
           "placeholders are single-line")
    expect(peeled.display.contains("<div data-vault=\"0\" class=\"pull-quote\">"),
           "placeholder puts data-vault first (Toast's canonical order)")
    expect(BlockVault.restore(peeled.display, vault: peeled.vault) == vaultBody,
           "peel → restore is byte-identical")
    expect(BlockVault.restore(peeled.display.replacingOccurrences(of: "\n>\n", with: "\n> \n"),
                              vault: peeled.vault) == vaultBody,
           "restore undoes Toast's empty-quote-line padding")
    let removed = BlockVault.replace(1, in: vaultBody, vault: peeled.vault, with: "")
    expect(!removed.contains("callout") && removed.contains("pull-quote") && removed.contains("<figure>"),
           "replace(index, with: empty) deletes exactly that block")
    let edited = BlockVault.replace(0, in: vaultBody, vault: peeled.vault,
                                    with: "<div class=\"pull-quote\">New quote.</div>")
    expect(edited.contains("New quote.") && !edited.contains("Single line quote."),
           "replace(index) swaps exactly that block")

    // 10b. Marker substitution (the canvas insertion path).
    let markerBody = "Para one.\n\n\(BlockVault.insertionMarker)\n\nPara two."
    let landed = BlockVault.substituteMarker(in: markerBody, with: BlockKind.pullquote.markdown)
    expect(landed == "Para one.\n\n<div class=\"pull-quote\">Your pull quote here.</div>\n\nPara two.",
           "marker swaps for the block with clean spacing")
    expect(BlockVault.substituteMarker(in: markerBody, with: "") == "Para one.\n\nPara two.",
           "empty substitution (cancel) removes the marker cleanly")
    expect(BlockVault.substituteMarker(in: "No marker here.", with: "<hr>").hasSuffix("<hr>\n"),
           "vanished marker appends the block instead of dropping it")

    // 10c. Applied full text keeps keys the loaded document never had.
    MainActor.assumeIsolated {
        let loadedDoc = EditorDocument(repoPath: "content/articles/2026-01-01-x.md",
                                       text: "---\ntitle: X\ndate: 2026-01-01\nstatus: draft\n---\n\nOld body.\n",
                                       sha: "abc", isNew: false)
        loadedDoc.applyFullText("---\ntitle: X\ntldr: Survives the source sheet\ntopic: geopolitics\ndate: 2026-01-01\nstatus: draft\n---\n\nNew body.\n")
        let reserialized = loadedDoc.serialized()
        expect(reserialized.contains("tldr: Survives the source sheet")
               && reserialized.contains("topic: geopolitics")
               && reserialized.contains("New body."),
               "applyFullText keeps unknown frontmatter keys (tldr/topic)")
        expect(loadedDoc.dirty, "applied full text marks the document dirty")
    }

    // 10d. Schema notes: blueprints carry guidance; publish strips it.
    let blueprint = newArticleTemplate(title: "T", author: "", template: .deepDive)
    expect(blueprint.contains("class=\"draft-note\"")
           && blueprint.contains("Nut graf") && blueprint.contains("Kicker"),
           "deep-dive blueprint carries lede/nut-graf/kicker schema notes")
    let stripped = BlockVault.stripSchemaNotes(from: FrontmatterDoc.parse(blueprint).body)
    expect(!stripped.contains("draft-note") && stripped.contains("## The takeaway")
           && stripped.contains("Write the kicker here."),
           "stripSchemaNotes removes every note and keeps the content")
    MainActor.assumeIsolated {
        let d = EditorDocument(repoPath: "content/articles/2026-01-01-y.md",
                               text: newArticleTemplate(title: "Y", author: "", template: .newsBrief),
                               sha: nil, isNew: true)
        d.publishNow()
        expect(!d.bodyText.contains("draft-note") && d.bodyText.contains("**What happened:**"),
               "publishNow strips schema notes from the body")
    }

    // 11. Article templates ship structured bodies with design blocks.
    let deep = newArticleTemplate(title: "Test Piece", author: "", template: .deepDive)
    expect(deep.contains("type: deep-dive") && deep.contains("## The case")
           && deep.contains("## The counter") && deep.contains("## The takeaway"),
           "deep-dive template structured (thesis/antithesis/kicker)")
    let brief = newArticleTemplate(title: "Test Piece", author: "", template: .newsBrief)
    expect(brief.contains("**What happened:**") && brief.contains("callout--info"),
           "news-brief template structured")
    expect(newArticleTemplate(title: "Test Piece", author: "") == newArticleTemplate(title: "Test Piece", author: "", template: .blank),
           "blank template unchanged (backwards compatible)")

    // ── Date buckets (library + ⌘K grouping) ──────────────────────
    let iso = DateFormatter()
    iso.dateFormat = "yyyy-MM-dd"
    let cal = Calendar.current
    func isoDay(_ offset: Int) -> String {
        iso.string(from: cal.date(byAdding: .day, value: offset, to: Date())!)
    }
    expect(DateBucket.label(for: isoDay(0)) == "Today", "date bucket: today")
    expect(DateBucket.label(for: isoDay(-1)) == "Yesterday", "date bucket: yesterday")
    expect(DateBucket.label(for: isoDay(-4)) == "This week", "date bucket: this week")
    expect(DateBucket.label(for: isoDay(-20)) == "This month", "date bucket: this month")
    expect(DateBucket.label(for: isoDay(3)) == "Upcoming", "date bucket: scheduled ahead")
    expect(DateBucket.label(for: "2019-04-02") == "2019", "date bucket: past years keep their year")
    expect(DateBucket.label(for: "") == "Undated", "date bucket: unparsable date is not dropped")

    let mixed = [
        ContentEntry(path: "a", name: "a.md", title: "A", date: isoDay(-1), status: "published"),
        ContentEntry(path: "b", name: "b.md", title: "B", date: isoDay(0), status: "published"),
        ContentEntry(path: "c", name: "c.md", title: "C", date: isoDay(-40), status: "draft")
    ]
    let grouped = DateBucket.group(mixed)
    expect(grouped.first?.0 == "Today" && grouped.count == 3,
           "date grouping orders newest bucket first")
    expect(grouped.reduce(0) { $0 + $1.1.count } == mixed.count,
           "date grouping keeps every entry")

    return (ok, passed)
}
