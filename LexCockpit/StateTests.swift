import Foundation

/// Self-tests for the parts the August 2026 audit found untested.
///
/// The 55 tests that existed covered frontmatter, slugs, blocks and date
/// buckets — all of which already worked. The four subsystems with no tests
/// at all were Supabase, the updater, the Keychain and the offline queue,
/// and every bug found that day was in those four. This closes the two that
/// are pure logic and need no network.
@MainActor
func runStateSelfTests() -> (ok: Bool, passed: Int) {
    var ok = true
    var passed = 0
    func expect(_ cond: Bool, _ name: String) {
        print(cond ? "PASS  \(name)" : "FAIL  \(name)")
        if cond { passed += 1 } else { ok = false }
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

    // ── Is the tracker still being fed? ─────────────────────────────────
    // An empty changelog is the correct answer almost every day, which is
    // exactly why it cannot be trusted on its own.
    let noon = Date(timeIntervalSince1970: 1_786_000_000)          // fixed clock
    func fresh(_ h: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: noon.addingTimeInterval(-h * 3600))
    }
    expect(TrackerFreshness.verdict(lastFetched: fresh(3), success: true,
                                    errors: [], now: noon) == nil,
           "tracker: a fetch three hours ago is fine")
    expect(TrackerFreshness.verdict(lastFetched: fresh(30), success: true,
                                    errors: [], now: noon) == nil,
           "tracker: a single late run is not yet an alarm")
    expect(TrackerFreshness.verdict(lastFetched: fresh(50), success: true,
                                    errors: [], now: noon)?.contains("updated daily") == true,
           "tracker: past the daily promise, the promise is the wrong part")
    expect(TrackerFreshness.verdict(lastFetched: fresh(200), success: true,
                                    errors: [], now: noon)?.contains("8 days") == true,
           "tracker: a long stall is reported in days, not hours")
    expect(TrackerFreshness.verdict(lastFetched: fresh(1), success: true,
                                    errors: ["EUR-Lex 503"], now: noon)?
            .contains("EUR-Lex 503") == true,
           "tracker: a reported error beats a recent timestamp")
    expect(TrackerFreshness.verdict(lastFetched: fresh(1), success: false,
                                    errors: [], now: noon) != nil,
           "tracker: fetchSuccess=false is an alarm on its own")
    expect(TrackerFreshness.verdict(lastFetched: nil, success: true,
                                    errors: [], now: noon) != nil,
           "tracker: no timestamp means the promise cannot be checked")
    expect(TrackerFreshness.verdict(lastFetched: "not a date", success: true,
                                    errors: [], now: noon) != nil,
           "tracker: an unparseable timestamp is not silently treated as fresh")

    // The real shape the site writes, fractional seconds and all.
    expect(TrackerFreshness.parseISO("2026-08-09T07:53:26.016Z") != nil,
           "tracker: the site's own timestamp format parses")
    expect(TrackerFreshness.parseISO("2026-08-09T07:53:26Z") != nil,
           "tracker: a timestamp without fractional seconds also parses")

    // ── The defence desk's own rule, made unbreakable ───────────────────
    // data/defence-programmes.json states: "Rows without a citable public
    // source are not published; the categories they would cover are listed
    // as gaps instead." These tests are that sentence.
    let clock = Fitment.day("2026-08-13")!

    var good = Fitment()
    good.category = "Platform"; good.system = "Construction"; good.supplier = "tkMS / NVL"
    good.tier = "Prime"; good.status = "confirmed"
    good.quote = "tkMS eine deutliche Mehrheit der Anteile hält"
    good.sourcePublisher = "hartpunkt.de"
    good.sourceURL = "https://www.hartpunkt.de/f127-beschaffungsprozess/"
    good.retrieved = "2026-08-05"
    expect(good.problems(today: clock).isEmpty, "defence: a fully sourced row is publishable")

    var noSource = good; noSource.sourceURL = ""
    expect(noSource.problems(today: clock).contains { $0.contains("source URL") },
           "defence: confirmed without a document is blocked")

    var noQuote = good; noQuote.quote = "   "
    expect(noQuote.problems(today: clock).contains { $0.contains("verbatim quote") },
           "defence: confirmed without the quote it rests on is blocked")

    var noDate = good; noDate.retrieved = ""
    expect(noDate.problems(today: clock).contains { $0.contains("retrieval date") },
           "defence: confirmed without a retrieval date is blocked")

    var planned = good
    planned.status = "planned"; planned.sourceURL = ""; planned.quote = ""; planned.retrieved = ""
    expect(planned.problems(today: clock).isEmpty,
           "defence: a stated intention may be recorded without a contract document")

    var future = good; future.retrieved = "2027-01-01"
    expect(future.problems(today: clock).contains { $0.contains("future") },
           "defence: a row cannot have been read tomorrow")

    var malformed = good; malformed.retrieved = "5 Aug 2026"
    expect(malformed.problems(today: clock).contains { $0.contains("yyyy-MM-dd") },
           "defence: the retrieval date must be a date the site can sort")

    var notALink = good; notALink.sourceURL = "hartpunkt.de/f127"
    expect(notALink.problems(today: clock).contains { $0.contains("not a link") },
           "defence: a source that cannot be opened is not a source")

    var nameless = good; nameless.supplier = ""
    expect(nameless.problems(today: clock).contains { $0.contains("supplier") },
           "defence: a supplier row names a supplier")

    // The snapshot rule: fine to publish, but say how old it is.
    expect(good.staleness(today: clock) == nil, "defence: a row read 8 days ago is current")
    var old = good; old.retrieved = "2025-06-01"
    expect((old.staleness(today: clock) ?? 0) > Fitment.staleAfterDays,
           "defence: a row past its shelf life is flagged, not hidden")
    expect(old.problems(today: clock).isEmpty,
           "defence: staleness warns — it never blocks, because old is not wrong")

    // The evidence scale comes from the file, so the picker cannot drift.
    let fromFile = EvidenceScale(meta: ["status_scale": [
        "confirmed": "Contract, official document or parliamentary record",
        "reported": "Reported by specialist press as decided; no contract document seen"]])
    expect(fromFile.levels.map { $0.key } == ["confirmed", "reported"],
           "defence: the scale is read from the file, strongest first")
    expect(EvidenceScale(meta: nil).levels.count == 5,
           "defence: a file without a scale falls back to the published five")

    // Round-trip: the dictionary the file gets back is the row it was given.
    let round = Fitment(good.dictionary)
    expect(round.supplier == good.supplier && round.quote == good.quote
           && round.retrieved == good.retrieved && round.status == good.status,
           "defence: a row survives the trip through the file unchanged")

    // ── Retention and the pipeline heartbeat ────────────────────────────
    func aged(_ days: Int) -> ReviewQueueItem {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return ReviewQueueItem(id: UUID().uuidString, title: "t", source_url: nil, snippet: nil,
                               published_at: nil, relevance_score: nil, relevance_reason: nil,
                               status: "queued",
                               created_at: f.string(from: Date().addingTimeInterval(-Double(days) * 86_400)),
                               source_name: "S", source_slug: nil, region: nil)
    }
    expect((aged(3).ageDays ?? -1) == 3, "retention: an item knows how long it has waited")
    expect(aged(3).ageDays! < ReviewQueueItem.retainQueuedDays - 7,
           "retention: a fresh item shows no countdown")
    expect(aged(26).ageDays! >= ReviewQueueItem.retainQueuedDays - 7,
           "retention: the countdown starts a week before deletion, not on the day")
    expect(ReviewQueueItem.retainQueuedDays == 30,
           "retention: the app mirrors the ingest function's 30-day default")

    let undated = ReviewQueueItem(id: "x", title: "t", source_url: nil, snippet: nil,
                                  published_at: nil, relevance_score: nil, relevance_reason: nil,
                                  status: "queued", created_at: nil, source_name: nil,
                                  source_slug: nil, region: nil)
    expect(undated.ageDays == nil,
           "retention: an item with no timestamp is never counted down — unknown is not old")

    // ── The updater's version comparison, which shipped untested ────────
    expect(UpdateChecker.isNewer("0.26.0", than: "0.25.0"), "update: 0.26.0 > 0.25.0")
    expect(!UpdateChecker.isNewer("0.25.0", than: "0.25.0"), "update: equal is not newer")
    expect(!UpdateChecker.isNewer("0.24.1", than: "0.25.0"),
           "update: an older release never downgrades a newer install")
    expect(UpdateChecker.isNewer("0.25.1", than: "0.25.0"), "update: patch bump counts")
    expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"), "update: major beats minor")
    expect(!UpdateChecker.isNewer("0.25", than: "0.25.0"),
           "update: a short version is not newer than its padded self")

    // ── The tool register: the rule that separates a mount from a part ──
    // This is the whole derivation. If the comma stops mattering, the app
    // starts reporting 199 instruments instead of 30, and every one of the
    // extra 169 is an inner part of another tool.
    let js = """
      (function () {
        function $(s, r) { return (r || document).querySelector(s); }
        function $$(s, r) { return [].slice.call((r || document).querySelectorAll(s)); }
        function initFlow(root) {
          var svg = $('[data-ff-svg]', root);
          var btns = $$('[data-ff-route]', root);
        }
        function boot() { $$('[data-fundflow]').forEach(initFlow); }
      })();
      """
    let mounts = WorkspaceModel.mountPoints(in: js)
    expect(mounts == ["data-fundflow"],
           "tools: a mount point is queried without a root")
    expect(!mounts.contains("data-ff-svg"),
           "tools: an inner part queried WITH a root is not an instrument")
    expect(!mounts.contains("data-ff-route"),
           "tools: the same holds for $$ with a root")

    expect(WorkspaceModel.mountPoints(in: "document.querySelectorAll('[data-lagebild]')")
             == ["data-lagebild"],
           "tools: the plain querySelectorAll form counts too")
    expect(WorkspaceModel.mountPoints(in: "$$(\"[data-sbx]\")") == ["data-sbx"],
           "tools: double quotes are the same selector as single quotes")
    expect(WorkspaceModel.mountPoints(in: "$$('[data-x]', root)").isEmpty,
           "tools: a root argument disqualifies it, whitespace or not")

    // ── The cache stamp, which a naive comparison trips over ────────────
    let html = """
      <script src="/assets/js/main.js?v=5b9dbee4"></script>
      <script src="/assets/js/funding.js"></script>
      <div class="ff" data-fundflow></div>
      <div data-filter-root-extra></div>
      """
    let srcs = WorkspaceModel.scriptSources(in: html)
    expect(srcs.contains("assets/js/main.js"),
           "tools: the ?v= stamp is stripped before comparing")
    expect(srcs.contains("assets/js/funding.js"),
           "tools: an unstamped script compares equal too")

    expect(WorkspaceModel.mounts("data-fundflow", in: html),
           "tools: a bare attribute on a div counts as mounted")
    expect(!WorkspaceModel.mounts("data-filter-root", in: html),
           "tools: data-filter-root does not match data-filter-root-extra")

    // ── What the state means, because it decides what the user is told ──
    let dead = SiteTool(attribute: "data-threshold", name: "Threshold walker",
                        script: "assets/js/procurement.js",
                        pages: ["defence/procurement.html"],
                        unwiredPages: ["defence/procurement.html"])
    expect(dead.state == .dead,
           "tools: mounted where its script is absent is dead, not fine")
    let orphan = SiteTool(attribute: "data-sandbox", name: "Sandbox",
                          script: "assets/js/tech-lab.js", pages: [], unwiredPages: [])
    expect(orphan.state == .orphan,
           "tools: a script no page mounts is orphaned, not dead")
    let wired = SiteTool(attribute: "data-lagebild", name: "Report map",
                         script: "assets/js/lagebild.js",
                         pages: ["news/report-map.html"], unwiredPages: [])
    expect(wired.state == .wired, "tools: mounted and driven is wired")
    expect(dead.rank < orphan.rank && orphan.rank < wired.rank,
           "tools: findings sort above working instruments")

    expect(SiteTool.readableName(for: "data-fundflow") == "Funding route channel",
           "tools: a known attribute gets its editorial name")
    expect(SiteTool.readableName(for: "data-brand-new-thing") == "Brand new thing",
           "tools: an unknown one is derived and looks underived")

    // ── Der Layout-Editor darf nichts verlieren ────────────────────────
    // Das ist die Zusage, auf der alles andere steht: eine Seitendatei
    // geht durch den Editor und kommt vollstaendig wieder heraus, auch
    // die Felder und Blocktypen, die dieser Build nie gesehen hat.
    let pageJSON = """
    {
      "id": "probe",
      "title": "Probe",
      "target": "x/index.html",
      "_note": "ein Feld, das die App nicht kennt",
      "zukunft": { "tief": [1, 2, 3], "an": true },
      "sections": [
        {
          "id": "a",
          "heading": "Erster",
          "eyebrow": ["Auge"],
          "unbekannt": "bleibt",
          "blocks": [
            { "type": "lead", "text": "eins" },
            { "type": "kachelgitter", "spalten": 3, "eintraege": ["x", "y"] },
            { "type": "prose", "text": "zwei" }
          ]
        }
      ]
    }
    """
    do {
        let page = try SitePage.parse(path: "data/pages/probe.json", sha: "abc", json: pageJSON)
        expect(page.id == "probe", "layout: die Kennung kommt aus dem Dateinamen")
        expect(page.sections.count == 1 && page.sections[0].blocks.count == 3,
               "layout: Abschnitte und Bloecke werden gelesen")
        expect(page.sections[0].blocks[1].type == "kachelgitter",
               "layout: ein unbekannter Blocktyp wird gelesen, nicht verworfen")
        expect(!page.sections[0].blocks[1].isEditable,
               "layout: und er meldet sich als nicht bearbeitbar")

        let out = try page.encoded()
        for needle in ["_note", "zukunft", "unbekannt", "kachelgitter", "eintraege", "spalten"] {
            expect(out.contains(needle),
                   "layout: \(needle) ueberlebt das Schreiben")
        }
        expect(out.contains("\"spalten\" : 3") || out.contains("\"spalten\": 3"),
               "layout: eine ganze Zahl bleibt eine ganze Zahl, kein 3.0")

        // Verschieben aendert die Reihenfolge und sonst nichts.
        var moved = page
        moved.sections[0].blocks.swapAt(0, 2)
        expect(moved.sections[0].blocks[0].text == "zwei"
               && moved.sections[0].blocks[2].text == "eins",
               "layout: Verschieben vertauscht genau zwei Bloecke")
        let out2 = try moved.encoded()
        expect(out2.contains("kachelgitter"),
               "layout: der unbekannte Block ueberlebt auch das Verschieben")
        expect(out2.count == out.count,
               "layout: Verschieben aendert die Groesse der Datei nicht")

        // Ein frischer Block traegt die Felder seines Typs.
        let img = PageBlock.make("image")
        expect(img.type == "image" && img.fields["alt"] != nil,
               "layout: ein neues Bild bringt sein alt-Feld mit")
        expect(PageBlock.make("gaps").fields["items"] != nil,
               "layout: neue Luecken bringen ihre Liste mit")
    } catch {
        expect(false, "layout: die Probedatei liess sich nicht lesen (\(error))")
    }

    // ── Die Design-Tokens ──────────────────────────────────────────────
    // Der Kern ist nicht das Bearbeiten, sondern das Nicht-Anfassen: eine
    // Datei mit neuntausend Zeilen darf beim Speichern nur an den Stellen
    // anders sein, die jemand geaendert hat.
    let cssProbe = """
    /* Kopf */
    :root {
      --bg:      #F7F5F0;
      --ink:     #111111;
      --muted:   #656C7A;
      --surface: #FFFFFF;
      --accent:  #1B2A4A;
      --bg-cream: var(--bg);
      --max-w:   1200px;
    }
    .etwas { color: var(--ink); }
    :root[data-theme="dark"] {
      --bg:      #12141B;
      --ink:     #D9DBE2;
      --surface: #1B2030;
    }
    .anderes { color: red; }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg:      #12141B;
        --ink:     #D9DBE2;
        --surface: #1B2030;
      }
    }
    .ende { display: none; }
    """
    do {
        let sheet = try DesignSheet(css: cssProbe, sha: "s1")
        expect(sheet.blocksFound == 3, "design: alle drei Token-Bloecke gefunden")
        expect(sheet.tokens.count == 7, "design: sieben helle Tokens gelesen")
        expect(sheet.tokens.first { $0.name == "bg" }?.dark == "#12141B",
               "design: der Dunkelwert wird dem Token zugeordnet")
        expect(sheet.tokens.first { $0.name == "max-w" }?.dark == nil,
               "design: ein Token ohne Dunkelwert bekommt keinen erfunden")
        expect(sheet.darkOutOfSync.isEmpty,
               "design: beide Dunkel-Bloecke tragen dieselben Tokens")

        expect(sheet.rendered() == cssProbe,
               "design: ohne Aenderung ist die Datei zeichengleich")

        // Eine helle Farbe aendern.
        var a = sheet
        if let i = a.tokens.firstIndex(where: { $0.name == "muted" }) {
            a.tokens[i].light = "#5A6070"
        }
        let outA = a.rendered()
        expect(outA.contains("--muted:   #5A6070;"), "design: der neue Wert steht drin")
        expect(!outA.contains("#656C7A"), "design: der alte Wert ist weg")
        expect(outA.count == cssProbe.count, "design: gleiche Laenge, nur der Wert ersetzt")
        expect(outA.contains(".anderes { color: red; }") && outA.contains(".ende { display: none; }"),
               "design: der Rest der Datei ist unberuehrt")

        // Einen Dunkelwert aendern: muss in BEIDE Bloecke.
        var b = sheet
        if let i = b.tokens.firstIndex(where: { $0.name == "surface" }) {
            b.tokens[i].dark = "#202638"
        }
        let outB = b.rendered()
        expect(outB.components(separatedBy: "#202638").count - 1 == 2,
               "design: ein Dunkelwert wird in beide Dunkel-Bloecke geschrieben")
        expect(!outB.contains("#1B2030"), "design: der alte Dunkelwert ist nirgends mehr")
        expect(outB.contains("--surface: #FFFFFF;"),
               "design: der helle Wert desselben Tokens bleibt unangetastet")

        // Kontrast, gegen von Hand nachgerechnete Werte.
        let t = sheet.tokens
        if let r = CSSColour.contrast("#656C7A", "#FFFFFF", in: t, dark: false) {
            expect(abs(r - 5.28) < 0.02, "design: Kontrast 5.28 fuer muted auf weiss")
        } else { expect(false, "design: Kontrast fuer muted konnte nicht gerechnet werden") }
        if let r = CSSColour.contrast("#1B2A4A", "#FFFFFF", in: t, dark: false) {
            expect(abs(r - 14.22) < 0.02, "design: Kontrast 14.22 fuer accent auf weiss")
        } else { expect(false, "design: Kontrast fuer accent konnte nicht gerechnet werden") }
        if let r = CSSColour.contrast("#C2A675", "#FFFFFF", in: t, dark: false) {
            expect(abs(r - 2.33) < 0.02, "design: Gold auf weiss ist 2.33 und faellt durch")
        } else { expect(false, "design: Kontrast fuer Gold konnte nicht gerechnet werden") }

        // var() eine Ebene tief, und was nicht rechenbar ist.
        expect(CSSColour.parse("var(--bg)", in: t, dark: false) != nil,
               "design: var(--bg) wird aufgeloest")
        expect(CSSColour.parse("var(--bg)", in: t, dark: true).map { $0.r < 0.2 } == true,
               "design: var(--bg) loest im Dunkelmodus den Dunkelwert auf")
        expect(CSSColour.contrast("1200px", "#FFFFFF", in: t, dark: false) == nil,
               "design: was keine Farbe ist, liefert nichts statt 1.0")
    } catch {
        expect(false, "design: die Probe-CSS liess sich nicht lesen (\(error))")
    }

    // ── Bilder: was fehlt, muss auffallen ──────────────────────────────
    var img = PageBlock.make("image")
    expect(img.missing == ["file", "alt text", "credit", "size"],
           "bild: ein frischer Bildblock nennt alle vier fehlenden Angaben")
    expect(img.summary.contains("no alt text") && img.summary.contains("no credit"),
           "bild: der Mangel steht schon in der eingeklappten Zeile")

    img.fields["src"] = .string("/assets/images/pages/probe/x.jpg")
    img.fields["alt"] = .string("Was zu sehen ist")
    img.fields["credit"] = .string("Eigene Aufnahme, CC BY 4.0")
    img.fields["width"] = .number(1600)
    img.fields["height"] = .number(900)
    expect(img.missing.isEmpty, "bild: vollstaendig heisst keine Mangelmeldung")
    expect(!img.summary.contains("no "), "bild: dann ist die Zeile auch sauber")

    // Leerzeichen sind kein Alt-Text.
    var blank = img
    blank.fields["alt"] = .string("   ")
    expect(blank.missing == ["alt text"],
           "bild: ein Alt-Text aus Leerzeichen zaehlt nicht als Alt-Text")

    // Die Maße muessen als ganze Zahlen herauskommen, nicht als 1600.0.
    do {
        let page = SitePage(id: "probe", path: "data/pages/probe.json", sha: nil,
                            fields: ["id": .string("probe")],
                            sections: [PageSection(fields: ["id": .string("a")],
                                                   blocks: [img])])
        let out = try page.encoded()
        expect(out.contains("1600") && !out.contains("1600.0"),
               "bild: die Breite steht als 1600, nicht als 1600.0")
        expect(out.contains("CC BY 4.0"), "bild: die Lizenzangabe geht mit hinaus")
    } catch {
        expect(false, "bild: die Seite liess sich nicht schreiben (\(error))")
    }

    // ── Die neuen Blocktypen ───────────────────────────────────────────
    // Ueberschriften und Listen waren die groesste Luecke: 119 h3, 9 h4,
    // 82 ul und 16 ol auf der Website liessen sich vorher gar nicht
    // ausdruecken und wurden bei jeder Umstellung zu rohen Bloecken.
    var h = PageBlock.make("heading")
    h.fields["text"] = .string("Wo die Regel greift")
    expect(BlockRenderer.block(h, pad: 0) == "<h3>Wo die Regel greift</h3>",
           "block: eine Ueberschrift ist standardmaessig Stufe 3")
    h.fields["level"] = .number(4)
    expect(BlockRenderer.block(h, pad: 0) == "<h4>Wo die Regel greift</h4>",
           "block: Stufe 4 wird respektiert")
    h.fields["id"] = .string("regel")
    expect(BlockRenderer.block(h, pad: 0).contains("<h4 id=\"regel\">"),
           "block: eine Ueberschrift kann ein Sprungziel tragen")
    h.fields["level"] = .number(9)
    expect(BlockRenderer.block(h, pad: 0).hasPrefix("<h3"),
           "block: eine unsinnige Stufe faellt auf 3 zurueck statt h9 zu bauen")

    var li = PageBlock.make("list")
    li.fields["items"] = .array([.string("eins"), .string("zwei")])
    let ul = BlockRenderer.block(li, pad: 0)
    expect(ul.hasPrefix("<ul>") && ul.contains("<li>eins</li>") && ul.hasSuffix("</ul>"),
           "block: eine Liste ist ohne Angabe ungeordnet")
    li.fields["ordered"] = .bool(true)
    expect(BlockRenderer.block(li, pad: 0).hasPrefix("<ol>"),
           "block: ordered macht daraus eine nummerierte Liste")
    expect(li.summary.contains("2 numbered"),
           "block: die Zeile nennt Anzahl und Art der Liste")

    // ── Werkzeuge mit Kennung und Inhalt ───────────────────────────────
    // 27 Montagepunkte der Website tragen eine id, viele einen
    // Ladeplatzhalter. Ohne beides waere keine Seite mit einem Werkzeug
    // vollstaendig aus Bloecken baubar.
    var tl = PageBlock.make("tool")
    tl.fields["attribute"] = .string("data-bayes")
    tl.fields["cls"] = .string("bayes")
    tl.fields["id"] = .string("alert")
    tl.fields["params"] = .object(["data-state": .string("loading"),
                                   "data-truth": .string("threat")])
    tl.fields["inner"] = .string("  <p class=\"tool-head\">Lade</p>")
    let out = BlockRenderer.block(tl, pad: 0)
    expect(out.contains("id=\"alert\""), "block: ein Werkzeug traegt seine Kennung")
    expect(out.contains("data-bayes"), "block: und seinen Montagepunkt")
    expect(out.range(of: "data-state=\"loading\" data-truth=\"threat\"") != nil,
           "block: Parameter stehen sortiert, damit beide Renderer gleich bauen")
    expect(out.contains("<p class=\"tool-head\">Lade</p>"),
           "block: der Inhalt des Containers geht woertlich hinaus")

    expect(PageBlock.editable.contains("heading") && PageBlock.editable.contains("list"),
           "block: die neuen Typen lassen sich auch anlegen")

    // ── Direkt in der Seite tippen ─────────────────────────────────────
    // contenteditable gibt zurueck, was der Browser daraus gemacht hat,
    // und Browser machen daraus einiges. Ungefiltert landete das auf der
    // Website.
    let dirty = "Ein Satz mit <a href=\"/x\" class=\"xl\">Link</a> und "
              + "<span style=\"font-weight:700\">Fettem</span>, dazu "
              + "<div>ein Kasten</div> und <font color=\"red\">Farbe</font>."
    let clean = BlockRenderer.sanitiseInline(dirty)
    expect(clean.contains("<a href=\"/x\">Link</a>"),
           "tippen: ein Link ueberlebt, aber ohne die Klasse des Browsers")
    expect(clean.contains("<span>Fettem</span>"),
           "tippen: span bleibt, sein Inline-Stil nicht")
    expect(!clean.contains("<div>") && clean.contains("ein Kasten"),
           "tippen: ein div faellt weg, sein Inhalt bleibt")
    expect(!clean.contains("<font"), "tippen: font faellt ganz weg")
    expect(!clean.contains("class="), "tippen: keine Klasse aus dem Browser kommt durch")

    expect(BlockRenderer.sanitiseInline("a&nbsp;b   c\nd") == "a b c d",
           "tippen: geschuetzte Leerzeichen und Umbrueche werden normal")
    expect(BlockRenderer.sanitiseInline("<script>alert(1)</script>Text") == "alert(1)Text",
           "tippen: ein script-Tag ist kein erlaubtes Tag und faellt weg")

    // ── Verschieben, und die Arithmetik dahinter ────────────────────────
    // Wird ein Block entfernt, ruecken alle folgenden um eins vor. Wer das
    // vergisst, legt ihn eine Stelle zu weit hinten ab, und zwar nur beim
    // Verschieben nach unten, was beim Ausprobieren leicht durchgeht.
    func moved(_ types: [String], from: Int, to: Int) -> [String] {
        var a = types
        let m = a.remove(at: from)
        var t = to
        if from < to { t -= 1 }
        a.insert(m, at: max(0, min(t, a.count)))
        return a
    }
    expect(moved(["a","b","c","d"], from: 0, to: 2) == ["b","a","c","d"],
           "verschieben: nach unten landet der Block VOR dem Ziel")
    expect(moved(["a","b","c","d"], from: 3, to: 1) == ["a","d","b","c"],
           "verschieben: nach oben landet er ebenfalls vor dem Ziel")
    expect(moved(["a","b","c"], from: 0, to: 0) == ["a","b","c"],
           "verschieben: auf sich selbst aendert nichts")

    // ── Die anfassbare Fassung darf nichts anderes sein ─────────────────
    // Sie ist das veroeffentlichte HTML plus ein Attribut je Block. Waere
    // sie mehr, bearbeitete man nicht mehr die Seite, sondern ein Bild.
    do {
        let probe = """
        { "id":"p","target":"x.html","sections":[
          { "id":"a","heading":"Kopf","eyebrow":["Auge"],
            "blocks":[ {"type":"lead","text":"eins"},
                       {"type":"prose","text":"zwei"} ] } ] }
        """
        let pg = try SitePage.parse(path: "data/pages/p.json", sha: nil, json: probe)
        let plain = BlockRenderer.body(pg)
        let live = BlockRenderer.editableBody(pg)
        expect(live.contains("data-blk=\"0.0\"") && live.contains("data-blk=\"0.1\""),
               "anfassen: jeder Block traegt seine Position")
        expect(live.contains("data-sec=\"0\""), "anfassen: der Abschnitt auch")
        var stripped = live
        for needle in [" data-blk=\"0.0\"", " data-blk=\"0.1\"", " data-sec=\"0\""] {
            stripped = stripped.replacingOccurrences(of: needle, with: "")
        }
        expect(stripped == plain,
               "anfassen: ohne die Attribute ist es Zeichen fuer Zeichen das veroeffentlichte HTML")
    } catch {
        expect(false, "anfassen: die Probe liess sich nicht lesen (\(error))")
    }

    return (ok, passed)
}
