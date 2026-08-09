import Foundation

/// Self-tests for the parts the August 2026 audit found untested.
///
/// The 55 tests that existed covered frontmatter, slugs, blocks and date
/// buckets — all of which already worked. The four subsystems with no tests
/// at all were Supabase, the updater, the Keychain and the offline queue,
/// and every bug found that day was in those four. This closes the two that
/// are pure logic and need no network.
@MainActor
func runStateSelfTests() -> Bool {
    var ok = true
    func expect(_ cond: Bool, _ name: String) {
        print(cond ? "PASS  \(name)" : "FAIL  \(name)")
        if !cond { ok = false }
    }

    // ── LoadState: the distinction that cost an hour ────────────────────
    let never: LoadState<[Int]> = .never
    expect(!never.isConfirmedEmpty,
           "state: .never is NOT confirmed-empty — the whole point")
    expect(never.value == nil, "state: .never carries no value")

    let empty: LoadState<[Int]> = .loaded([], at: Date())
    expect(empty.isConfirmedEmpty,
           "state: .loaded([]) IS confirmed-empty")
    expect(empty.stamp != nil, "state: a loaded state carries its timestamp")

    var refreshing: LoadState<[Int]> = .loaded([1, 2, 3], at: Date())
    refreshing.beginLoading()
    expect(refreshing.value?.count == 3,
           "state: refreshing keeps the previous value on screen")
    expect(refreshing.isLoading, "state: refreshing reports loading")
    expect(!refreshing.isConfirmedEmpty,
           "state: a refreshing panel is never confirmed-empty")

    let failed: LoadState<[Int]> = .failed("403", at: Date())
    expect(failed.error == "403", "state: failure keeps its reason")
    expect(!failed.isConfirmedEmpty, "state: a failure is not an empty list")

    expect(never.provenance(source: "q").contains("not loaded"),
           "state: provenance says 'not loaded yet' before the first fetch")
    expect(empty.provenance(source: "q").contains("q ·"),
           "state: provenance names its source")

    // ── The clustering rule: three sources are a story, one is a rewrite ─
    func item(_ t: String, _ src: String) -> ReviewQueueItem {
        ReviewQueueItem(id: UUID().uuidString, title: t, source_url: nil, snippet: nil,
                        published_at: nil, relevance_score: nil, relevance_reason: nil,
                        status: "queued", created_at: nil, source_name: src,
                        source_slug: nil, region: nil)
    }
    let three = [item("Council adopts sanctions package on Belarus", "A"),
                 item("EU sanctions package targets Belarus banks", "B"),
                 item("Belarus sanctions: what the package covers", "C")]
    let clustered = DeskBuilder.clusters(three)
    expect(clustered.contains { $0.key == "belarus" && $0.items.count == 3 },
           "desk: three items on one subject form a cluster")

    let two = Array(three.prefix(2))
    expect(DeskBuilder.clusters(two).isEmpty,
           "desk: two items do NOT — a brief needs three sources")

    let noise = [item("Taylor Swift announces album", "A"),
                 item("Rain expected in Vienna", "B"),
                 item("Council adopts sanctions package", "C")]
    expect(!DeskBuilder.clusters(noise).contains { $0.items.count >= 3 },
           "desk: unrelated items do not cluster")

    // ── The corroboration gate, which the first build did not have ──────
    let oneOutlet = [item("Brussels tightens export controls on drones", "Reuters"),
                     item("Export controls on drones tightened, Brussels says", "Reuters"),
                     item("What the new drone export controls cover", "Reuters")]
    expect(DeskBuilder.clusters(oneOutlet).isEmpty,
           "desk: three items from ONE outlet are a rewrite, not a story")

    var mixed = oneOutlet
    mixed.append(item("Drones: Brussels export controls draw response", "AFP"))
    expect(!DeskBuilder.clusters(mixed).isEmpty,
           "desk: a second independent outlet turns it into a story")

    // Verbs are not subjects — "3 items circling 'adds'" was a real row.
    let verby = [item("Council adds four names to the list", "A"),
                 item("Brussels adds two banks to the list", "B"),
                 item("Ministry adds a vessel to the list", "C")]
    expect(!DeskBuilder.clusters(verby).contains { $0.key == "adds" },
           "desk: a headline verb never becomes a cluster key")

    // One story must not fill the screen under three of its own words.
    let overlap = [item("EU sanctions Russia over Belarus transfers", "A"),
                   item("Russia sanctions: Belarus route targeted", "B"),
                   item("Belarus and Russia hit by new sanctions", "C")]
    let ids = DeskBuilder.clusters(overlap).flatMap { $0.items.map(\.id) }
    expect(ids.count == Set(ids).count,
           "desk: clusters are disjoint — no item is listed twice")

    // ── HTML entities: a real queue title read "list &#038; adds" ───────
    expect("list &#038; adds".decodingHTMLEntities == "list & adds",
           "entities: numeric &#038; becomes &")
    expect("Tom &amp; Jerry".decodingHTMLEntities == "Tom & Jerry",
           "entities: named &amp; becomes &")
    expect("a &amp;#038; b".decodingHTMLEntities == "a & b",
           "entities: a double-encoded feed decodes in two passes")
    expect("AT&T merger".decodingHTMLEntities == "AT&T merger",
           "entities: a bare ampersand is left exactly as it is")
    expect("Rates rise &hellip; again".decodingHTMLEntities == "Rates rise … again",
           "entities: named punctuation decodes")
    expect("&#x26; and &#8364;".decodingHTMLEntities == "& and €",
           "entities: hex and decimal both decode")
    expect("Q&A: what next".decodingHTMLEntities == "Q&A: what next",
           "entities: an ampersand with no semicolon is not an entity")

    // ── Seeding a draft: the app positions material and writes no prose ─
    func seedItem(_ t: String, _ src: String, _ url: String, _ snip: String) -> ReviewQueueItem {
        ReviewQueueItem(id: UUID().uuidString, title: t, source_url: url, snippet: snip,
                        published_at: "2026-08-08T10:00:00Z", relevance_score: 0.9,
                        relevance_reason: nil, status: "queued", created_at: nil,
                        source_name: src, source_slug: nil, region: nil)
    }
    let seeds = [
        seedItem("Council adopts sanctions package &#038; adds two banks", "Reuters",
                 "https://example.org/a", "The package covers\ntwo banks and a vessel."),
        seedItem("Sanctions package: what it covers", "AFP",
                 "https://example.org/b", "Brussels published the list on Friday."),
        seedItem("Belarus banks hit by new listings", "Politico",
                 "https://example.org/c", "")
    ]
    let seeded = DraftSeed.markdown(clusterKey: "belarus", items: seeds,
                                    author: "", today: "2026-08-09")

    /* `LEXCOCKPIT_DUMP_SEED=1 … --selftest` prints the whole generated file.
       Assertions prove invariants; reading the thing proves it is worth
       opening. Both are needed. */
    if ProcessInfo.processInfo.environment["LEXCOCKPIT_DUMP_SEED"] != nil {
        print("─── seeded draft ───\n\(seeded)─── end ───")
    }

    // THE rule. Every quoted line must be verbatim from an item — if this
    // test fails, the app has started writing sentences about the news.
    let quoted = seeded.components(separatedBy: "\n")
        .filter { $0.hasPrefix("> ") }
        .map { String($0.dropFirst(2)) }
    let allowed = Set(seeds.map { $0.displayTitle }
        + seeds.map { $0.displaySnippet.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ") })
    expect(!quoted.isEmpty && quoted.allSatisfy { allowed.contains($0) },
           "seed: every quoted line is verbatim from a queue item — no prose")

    expect(seeded.contains("Council adopts sanctions package & adds two banks"),
           "seed: the quoted title is entity-decoded, not raw feed markup")
    expect(!seeded.contains("&#038;"), "seed: no encoded entity survives into a draft")
    expect(seeded.contains("The package covers two banks and a vessel."),
           "seed: a multi-line snippet is flattened inside the blockquote")

    // Frontmatter must survive the editor untouched, or the site build breaks.
    let seededDoc = FrontmatterDoc.parse(seeded)
    expect(seededDoc.serialize() == seeded,
           "seed: the generated file round-trips byte-identically")

    /* The title is ours, not an outlet's — copying a headline starts a
       rewrite. Asserted on the parsed key, not on the raw text: the
       `sources:` list legitimately carries each outlet's own title, and a
       substring search cannot tell the two apart. */
    expect(seededDoc.scalar("title") == "Belarus",
           "seed: the article title is the shared word, not a feed's headline")
    expect(seeds.contains { $0.displayTitle == "Council adopts sanctions package & adds two banks" }
           && seededDoc.scalar("title") != "Council adopts sanctions package & adds two banks",
           "seed: a feed's own headline never becomes the title")
    expect(seeded.contains("    tier: secondary"),
           "seed: sources are seeded secondary — promoting one is the author's call")
    expect(seeded.contains("    url: https://example.org/c"),
           "seed: every source URL reaches the frontmatter")
    expect(seeded.contains("Reuters, AFP, Politico"),
           "seed: three outlets are named in the header")
    expect(seeded.contains("retrieved 2026-08-09"), "seed: each item carries its retrieval date")

    // One outlet is the case the method forbids, so the draft has to say so.
    let single = DraftSeed.markdown(clusterKey: "drones",
                                    items: [seeds[0], seedItem("Drones again", "Reuters",
                                                               "https://example.org/d", "")],
                                    author: "", today: "2026-08-09")
    expect(single.contains("One outlet only"),
           "seed: a single-outlet draft says plainly that it is a rewrite")
    expect(!seeded.contains("One outlet only"),
           "seed: a corroborated draft carries no such warning")

    expect(DraftSeed.outlets(seeds).count == 3, "seed: outlets are counted distinctly")

    // A lone item has no shared word, so it borrows its most specific one.
    let lone = seedItem("Commission opens countermeasures consultation", "Reuters",
                        "https://example.org/e", "")
    expect(DraftSeed.keyFor(lone) == "countermeasures",
           "seed: a single item keys on its longest surviving word")
    expect(!DeskBuilder.keywords(lone).contains("opens"),
           "seed: the stoplist applies to single items too")
    expect(DraftSeed.placeholderTitle(clusterKey: "") == "Untitled brief",
           "seed: an empty cluster key still yields a usable title")

    // ── The updater's version comparison, which shipped untested ────────
    expect(UpdateChecker.isNewer("0.26.0", than: "0.25.0"), "update: 0.26.0 > 0.25.0")
    expect(!UpdateChecker.isNewer("0.25.0", than: "0.25.0"), "update: equal is not newer")
    expect(!UpdateChecker.isNewer("0.24.1", than: "0.25.0"),
           "update: an older release never downgrades a newer install")
    expect(UpdateChecker.isNewer("0.25.1", than: "0.25.0"), "update: patch bump counts")
    expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"), "update: major beats minor")
    expect(!UpdateChecker.isNewer("0.25", than: "0.25.0"),
           "update: a short version is not newer than its padded self")

    return ok
}
