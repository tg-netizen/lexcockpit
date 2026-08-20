import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Content list entry

struct ContentEntry: Identifiable, Hashable {
    let path: String            // repo path, e.g. content/articles/2026-…-slug.md
    let name: String            // filename
    let title: String
    let date: String
    let status: String          // draft / concept / scheduled / published / —
    var preview: String = ""    // first body line (library row)
    var words: Int = 0
    var scheduled: String = ""  // scheduled_publish_at, if any
    var type: String = ""       // deep-dive / brief / …
    var topic: String = ""
    /// Set by the automated ingest pipeline (`ai_generated: true` / `origin: ai-ingest`).
    var aiGenerated: Bool = false
    var reviewRequired: Bool = false
    var id: String { path }

    var isDraft: Bool { status == "draft" || status == "concept" }
    /// True only when the ingest pipeline marked the Markdown as AI-generated.
    var isAIDraft: Bool { aiGenerated }

    /// Live URL: the site publishes at the file stem.
    func liveURL(site: String?) -> String? {
        guard status == "published", let base = site, !base.isEmpty else { return nil }
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        return base + "/articles/" + stem + ".html"
    }
}

// MARK: - Date buckets (Today / Yesterday / … — shared by library + ⌘K)

/// Groups entries by how recent they are, newest bucket first. Uses the
/// scheduled date when one is set (that's when the piece matters), else
/// the article date. Entries with an unparsable date land in "Undated"
/// rather than being silently dropped.
enum DateBucket {
    static func label(for iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(iso.prefix(10))) else { return "Undated" }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: day, to: today).day ?? 0
        if days < 0 { return "Upcoming" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 7 { return "This week" }
        if days <= 30 { return "This month" }
        let year = cal.component(.year, from: date)
        return year == cal.component(.year, from: today) ? "Earlier this year" : "\(year)"
    }

    private static let order = ["Upcoming", "Today", "Yesterday", "This week",
                                "This month", "Earlier this year"]

    /// Bucketed entries in display order; keeps each bucket's own order.
    static func group(_ entries: [ContentEntry]) -> [(String, [ContentEntry])] {
        var buckets: [String: [ContentEntry]] = [:]
        for e in entries {
            let key = label(for: e.scheduled.isEmpty ? e.date : e.scheduled)
            buckets[key, default: []].append(e)
        }
        return buckets.keys.sorted { a, b in
            let ia = order.firstIndex(of: a), ib = order.firstIndex(of: b)
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true          // named buckets before years
            case (nil, _?):    return false
            default:           return a > b          // years descending, "Undated" last-ish
            }
        }.map { ($0, buckets[$0] ?? []) }
    }
}

// MARK: - Open document

/// One open markdown document. Frontmatter is edited through the structured
/// form; the body through the raw editor. Unknown frontmatter keys are
/// preserved verbatim (see FrontmatterDoc). Saves go through the GitHub
/// Contents API with the SHA captured at load time — a mismatch surfaces the
/// conflict dialog, never a silent overwrite.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let repoPath: String
    let fileName: String
    let isNewFile: Bool
    private(set) var loadedSHA: String?
    private var fmDoc: FrontmatterDoc
    /// Full frontmatter structure adopted from an applied full text (source
    /// sheet, external editor, snapshot). Serialization starts from this when
    /// set, so keys the loaded document never had (tldr, topic, …) survive;
    /// the fmDoc BASELINE stays untouched so dirty/conflict logic keeps
    /// working. Cleared when a save/reload moves the baseline.
    private var overlayDoc: FrontmatterDoc?

    // Form fields
    @Published var title: String
    @Published var dateStr: String
    @Published var author: String
    @Published var descriptionText: String
    @Published var tagsCSV: String
    @Published var isDraft: Bool
    @Published var bodyText: String
    @Published var heroImagePath: String
    @Published var canvaCoverDesign: String = ""   // invisible frontmatter metadata
    var blockVault: [String] = []                  // originals behind canvas block cards
    @Published var scheduledAt: String = ""        // scheduled_publish_at (yyyy-MM-dd)
    @Published var uploadingImage = false
    @Published var restoreOffer: String?     // autosaved draft found on open
    var restoreOfferDate: Date?
    /// Imported Canva graphics [(design id, committed path)] — persisted as a
    /// raw frontmatter block `canva_designs` (never shown in the form).
    @Published var canvaDesigns: [(id: String, path: String)] = []
    private var pendingCanvaLines: [String]?
    private var autosaveTimer: Timer?

    // Which fields are locked because their YAML shape is too complex to bind
    let opaqueKeys: Set<String>

    // Save state
    @Published var saving = false
    @Published var conflict = false
    @Published var statusLine: String?
    @Published var lastCommitSHA: String?
    @Published var dirty = false { didSet { onDirtyChange?(dirty) } }
    var onDirtyChange: ((Bool) -> Void)?

    init(repoPath: String, text: String, sha: String?, isNew: Bool) {
        self.repoPath = repoPath
        self.fileName = repoPath.components(separatedBy: "/").last ?? repoPath
        self.loadedSHA = sha
        self.isNewFile = isNew
        let doc = FrontmatterDoc.parse(text)
        self.fmDoc = doc

        var opaque = Set<String>()
        for key in ["title", "date", "author", "description", "draft", "status", "hero_image", "canva_cover_design", "scheduled_publish_at"] where doc.isOpaque(key) {
            opaque.insert(key)
        }
        if doc.entries.first(where: { $0.key == "tags" }).map({ !$0.isBindableList }) == true {
            opaque.insert("tags")
        }
        self.opaqueKeys = opaque

        self.title = doc.scalar("title") ?? ""
        self.dateStr = doc.scalar("date") ?? ""
        self.author = doc.scalar("author") ?? ""
        self.descriptionText = doc.scalar("description") ?? ""
        self.tagsCSV = (doc.list("tags") ?? []).joined(separator: ", ")
        let draftField = doc.scalar("draft")
        let statusField = doc.scalar("status")
        self.isDraft = draftField == "true" || statusField == "draft" || (isNew && draftField == nil && statusField == nil)
        self.bodyText = doc.body
        self.heroImagePath = doc.scalar("hero_image") ?? ""
        self.canvaCoverDesign = doc.scalar("canva_cover_design") ?? ""
        self.scheduledAt = doc.scalar("scheduled_publish_at") ?? ""
        // parse canva_designs raw block: "- id: X" / "  path: Y" pairs
        if let entry = doc.entries.first(where: { $0.key == "canva_designs" }) {
            var pending: String?
            for line in entry.rawLines.dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- id:") { pending = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                else if t.hasPrefix("path:"), let id = pending {
                    canvaDesigns.append((id, String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)))
                    pending = nil
                }
            }
        }
    }

    /// Copy a freshly loaded document's state into this instance (used by
    /// standalone article windows whose StateObject exists before the fetch).
    func adopt(_ other: EditorDocument) {
        loadedSHA = other.loadedSHA
        fmDoc = other.exposedDoc
        overlayDoc = other.overlayDoc
        title = other.title; dateStr = other.dateStr; author = other.author
        descriptionText = other.descriptionText; tagsCSV = other.tagsCSV
        isDraft = other.isDraft; bodyText = other.bodyText
        heroImagePath = other.heroImagePath
        canvaCoverDesign = other.canvaCoverDesign
        canvaDesigns = other.canvaDesigns
        restoreOffer = other.restoreOffer
        restoreOfferDate = other.restoreOfferDate
        dirty = false
        startAutosave()
    }
    var exposedDoc: FrontmatterDoc { fmDoc }

    func appendCanvaDesign(id: String, path: String) {
        canvaDesigns.append((id, path))
        var lines = ["canva_designs:"]
        for d in canvaDesigns {
            lines.append("  - id: \(d.id)")
            lines.append("    path: \(d.path)")
        }
        pendingCanvaLines = lines
        recomputeDirty()
    }

    var slug: String {
        var stem = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        // strip a leading yyyy-mm-dd- date prefix for a cleaner commit message
        if stem.count > 11, stem.prefix(11).range(of: #"^\d{4}-\d{2}-\d{2}-$"#, options: .regularExpression) != nil {
            stem = String(stem.dropFirst(11))
        }
        return stem
    }

    /// Apply the form onto the parsed doc and serialize. Untouched entries
    /// (and every unknown key) are emitted verbatim from their original lines.
    func serialized() -> String {
        var doc = overlayDoc ?? fmDoc
        if !opaqueKeys.contains("title") { doc.setScalar("title", title) }
        if !opaqueKeys.contains("date"), !dateStr.isEmpty { doc.setScalar("date", dateStr) }
        if !opaqueKeys.contains("author"), !(author.isEmpty && doc.scalar("author") == nil) {
            doc.setScalar("author", author)
        }
        if !opaqueKeys.contains("description"), !(descriptionText.isEmpty && doc.scalar("description") == nil) {
            doc.setScalar("description", descriptionText)
        }
        if !opaqueKeys.contains("tags") {
            let items = tagsCSV.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !(items.isEmpty && doc.list("tags") == nil) { doc.setList("tags", items) }
        }
        if !opaqueKeys.contains("hero_image"), !(heroImagePath.isEmpty && doc.scalar("hero_image") == nil) {
            doc.setScalar("hero_image", heroImagePath)
        }
        if !opaqueKeys.contains("canva_cover_design"),
           !(canvaCoverDesign.isEmpty && doc.scalar("canva_cover_design") == nil) {
            doc.setScalar("canva_cover_design", canvaCoverDesign)
        }
        if !opaqueKeys.contains("scheduled_publish_at") {
            if scheduledAt.isEmpty {
                if doc.scalar("scheduled_publish_at") != nil { doc.removeEntry("scheduled_publish_at") }
            } else {
                doc.setScalar("scheduled_publish_at", scheduledAt)
            }
        }
        // Draft toggle drives whichever fields the file (or template) uses.
        if !opaqueKeys.contains("draft"), doc.scalar("draft") != nil {
            doc.setScalar("draft", isDraft ? "true" : "false")
        }
        if !opaqueKeys.contains("status"), let s = doc.scalar("status") {
            if isDraft, s != "scheduled" { doc.setScalar("status", "draft") }
            if !isDraft { doc.setScalar("status", "published") }
        }
        if let lines = pendingCanvaLines { doc.setRawLines("canva_designs", lines) }
        doc.body = bodyText
        return doc.serialize()
    }

    func recomputeDirty() {
        dirty = serialized() != fmDoc.serialize() || isNewFile && lastCommitSHA == nil
    }

    /// Optional writing goal from frontmatter `word_goal` (read-only —
    /// the form never writes it, unknown-key preservation keeps it intact).
    var wordGoal: Int? {
        exposedDoc.scalar("word_goal").flatMap { Int($0) }
    }

    /// The article's frontmatter type, which decides the build's word floor.
    var articleType: String {
        exposedDoc.scalar("type") ?? ""
    }

    enum PublishState { case draft, scheduled(String), published }
    var publishState: PublishState {
        if !isDraft { return .published }
        if !scheduledAt.isEmpty { return .scheduled(scheduledAt) }
        return .draft
    }

    func publishNow()  {
        isDraft = false
        scheduledAt = ""
        bodyText = BlockVault.stripSchemaNotes(from: bodyText)
        recomputeDirty()
    }

    /// Live site URL: the site publishes at the file stem (date-slug),
    /// not the bare slug.
    func liveURL(site: String?) -> String {
        let stem = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        return (site ?? "") + "/articles/" + stem + ".html"
    }
    func schedule(_ date: String) {
        isDraft = true
        scheduledAt = date
        // The site's daily build flips this live without the app — guidance
        // must leave the file at scheduling time already.
        bodyText = BlockVault.stripSchemaNotes(from: bodyText)
        recomputeDirty()
    }
    func backToDraft() { isDraft = true; scheduledAt = ""; recomputeDirty() }

    func save(repo: String, force: Bool = false, message customMessage: String? = nil) async {
        saving = true
        statusLine = nil
        do {
            var sha = loadedSHA
            if force {
                sha = try await GitHubAPI.file(repo: repo, path: repoPath).sha
            }
            let message = customMessage
                ?? ((isNewFile && lastCommitSHA == nil) ? "content: new \(slug)" : "content: edit \(slug)")
            let text = serialized()
            Snapshots.record(slug: slug, text: text)     // local history, every save
            let resp = try await GitHubAPI.put(repo: repo, path: repoPath,
                                               message: message, text: text, sha: sha)
            loadedSHA = resp.content?.sha ?? loadedSHA
            lastCommitSHA = resp.commit.sha
            fmDoc = FrontmatterDoc.parse(text)      // new baseline
            overlayDoc = nil
            pendingCanvaLines = nil
            dirty = false
            clearDraft()                            // local autosave no longer needed
            statusLine = "Committed \(String(resp.commit.sha.prefix(7))) — Netlify build starts automatically"
        } catch APIError.conflict {
            conflict = true
        } catch let urlErr as URLError {
            // Offline → queue the commit; it pushes automatically when the
            // network returns. Baseline moves to the queued text so further
            // edits diff against what will land.
            let text = serialized()
            CommitQueue.shared.enqueue(repo: repo, path: repoPath,
                                       message: customMessage
                                           ?? ((isNewFile && lastCommitSHA == nil)
                                               ? "content: new \(slug)" : "content: edit \(slug)"),
                                       text: text, sha: loadedSHA)
            fmDoc = FrontmatterDoc.parse(text)
            overlayDoc = nil
            dirty = false
            statusLine = "Offline (\(urlErr.code == .notConnectedToInternet ? "no connection" : urlErr.localizedDescription)) — commit queued, pushes automatically."
        } catch {
            statusLine = error.localizedDescription
        }
        saving = false
    }

    func reloadRemote(repo: String) async {
        do {
            let f = try await GitHubAPI.file(repo: repo, path: repoPath)
            guard let text = f.decodedText() else { return }
            loadedSHA = f.sha
            let doc = FrontmatterDoc.parse(text)
            fmDoc = doc
            overlayDoc = nil
            title = doc.scalar("title") ?? ""
            dateStr = doc.scalar("date") ?? ""
            author = doc.scalar("author") ?? ""
            descriptionText = doc.scalar("description") ?? ""
            tagsCSV = (doc.list("tags") ?? []).joined(separator: ", ")
            isDraft = doc.scalar("draft") == "true" || doc.scalar("status") == "draft"
            bodyText = doc.body
            heroImagePath = doc.scalar("hero_image") ?? ""
            canvaCoverDesign = doc.scalar("canva_cover_design") ?? ""
            scheduledAt = doc.scalar("scheduled_publish_at") ?? ""
            dirty = false
            statusLine = "Reloaded the remote version."
        } catch {
            statusLine = error.localizedDescription
        }
    }

    // MARK: Local autosave (crash safety — cleared after a successful commit)

    static var draftsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/drafts", isDirectory: true)
    }
    var draftURL: URL { Self.draftsDir.appendingPathComponent(slug + ".md") }

    func startAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosaveNow() }
        }
    }

    func autosaveNow() {
        guard dirty else { return }
        try? FileManager.default.createDirectory(at: Self.draftsDir, withIntermediateDirectories: true)
        try? serialized().write(to: draftURL, atomically: true, encoding: .utf8)
    }

    func clearDraft() {
        try? FileManager.default.removeItem(at: draftURL)
    }

    /// Apply a FULL markdown text (from an external editor session). The
    /// remote baseline stays untouched → dirty → normal SHA-checked save.
    func applyFullText(_ text: String) {
        let doc = FrontmatterDoc.parse(text)
        // Adopt the WHOLE parsed structure as serialization overlay — not
        // just the form fields — otherwise every key the loaded document
        // didn't already have (tldr, topic, custom keys) is silently dropped
        // on save. Found when the FCAS article lost its tldr through the
        // source sheet. The baseline (fmDoc) deliberately stays put.
        overlayDoc = doc
        title = doc.scalar("title") ?? title
        dateStr = doc.scalar("date") ?? dateStr
        author = doc.scalar("author") ?? author
        descriptionText = doc.scalar("description") ?? descriptionText
        tagsCSV = (doc.list("tags") ?? []).joined(separator: ", ")
        if let d = doc.scalar("draft") { isDraft = d == "true" }
        else if let s = doc.scalar("status") { isDraft = s == "draft" }
        heroImagePath = doc.scalar("hero_image") ?? heroImagePath
        scheduledAt = doc.scalar("scheduled_publish_at") ?? scheduledAt
        bodyText = doc.body
        recomputeDirty()
    }

    /// Apply an autosaved draft's fields. The remote baseline stays untouched,
    /// so the document is dirty and saves through the normal SHA-checked path.
    func restoreDraft() {
        guard let text = restoreOffer else { return }
        let doc = FrontmatterDoc.parse(text)
        title = doc.scalar("title") ?? title
        dateStr = doc.scalar("date") ?? dateStr
        author = doc.scalar("author") ?? author
        descriptionText = doc.scalar("description") ?? descriptionText
        tagsCSV = (doc.list("tags") ?? []).joined(separator: ", ")
        isDraft = doc.scalar("draft") == "true" || doc.scalar("status") == "draft"
        heroImagePath = doc.scalar("hero_image") ?? heroImagePath
        canvaCoverDesign = doc.scalar("canva_cover_design") ?? canvaCoverDesign
        scheduledAt = doc.scalar("scheduled_publish_at") ?? scheduledAt
        bodyText = doc.body
        restoreOffer = nil
        recomputeDirty()
        statusLine = "Unsaved draft restored — review and save."
    }
}

// MARK: - Content loading on the workspace model

struct ContentCacheEntry: Codable {
    let sha: String, title: String, date: String, status: String
    var preview: String? = nil
    var words: Int? = nil
    var scheduled: String? = nil
    var type: String? = nil
    var topic: String? = nil
    var aiGenerated: Bool? = nil
    var reviewRequired: Bool? = nil
}

extension WorkspaceModel {
    private var contentCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/content-cache5-\(site.id).json")
    }
    private func loadContentCache() -> [String: ContentCacheEntry] {
        (try? JSONDecoder().decode([String: ContentCacheEntry].self,
                                   from: Data(contentsOf: contentCacheURL))) ?? [:]
    }
    private func saveContentCache(_ c: [String: ContentCacheEntry]) {
        try? FileManager.default.createDirectory(
            at: contentCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: contentCacheURL) }
    }

    func loadContentList() async {
        guard let repo = site.repo, !repo.isEmpty else {
            contentState = .failed("No repo configured for this project (projects.json).", at: Date())
            return
        }
        let paths = site.content_paths ?? []
        guard !paths.isEmpty else {
            contentState = .failed("No content_paths configured for this project (projects.json).", at: Date())
            return
        }
        contentState.beginLoading()
        var entries: [ContentEntry] = []
        var cache = loadContentCache()
        do {
            // ONE tree request; frontmatter fetched only for new/changed files.
            let blobs = try await GitHubAPI.tree(repo: repo).filter { item in
                item.type == "blob" && item.path.hasSuffix(".md")
                    && paths.contains(where: { item.path.hasPrefix($0) })
            }
            var fresh: [String: ContentCacheEntry] = [:]
            try await withThrowingTaskGroup(of: (String, ContentCacheEntry)?.self) { group in
                for blob in blobs {
                    if let hit = cache[blob.path], hit.sha == blob.sha {
                        fresh[blob.path] = hit
                        continue
                    }
                    group.addTask {
                        guard let text = try await GitHubAPI.file(repo: repo, path: blob.path).decodedText()
                        else { return nil }
                        let doc = FrontmatterDoc.parse(text)
                        let status: String
                        if doc.scalar("status") == "concept" { status = "concept" }
                        else if doc.scalar("draft") == "true" || doc.scalar("status") == "draft" { status = "draft" }
                        else if doc.scalar("status") == "scheduled" { status = "scheduled" }
                        else if let s = doc.scalar("status") { status = s }
                        /* No status key means published — that is what the site
                           itself does (`status: data.status || 'published'` in
                           build-articles.js). This used to fall through to "—",
                           so the 14 live files whose frontmatter omits the key
                           showed a grey dot, offered no live link, and counted
                           as nothing published anywhere in the app. */
                        else { status = "published" }
                        let aiGenerated = doc.scalar("ai_generated") == "true"
                            || doc.scalar("origin") == "ai-ingest"
                        let reviewRequired = doc.scalar("review_required") == "true"
                            || aiGenerated
                        let body = doc.body
                        let preview = body.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .first { !$0.isEmpty && !$0.hasPrefix("<") }?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-! "))
                        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                        return (blob.path, ContentCacheEntry(
                            sha: blob.sha,
                            title: doc.scalar("title") ?? (blob.path as NSString).lastPathComponent,
                            date: doc.scalar("date") ?? String((blob.path as NSString).lastPathComponent.prefix(10)),
                            status: status,
                            preview: preview.map { String($0.prefix(110)) },
                            words: words,
                            scheduled: doc.scalar("scheduled_publish_at") ?? "",
                            type: doc.scalar("type") ?? "",
                            topic: doc.scalar("topic") ?? "",
                            aiGenerated: aiGenerated,
                            reviewRequired: reviewRequired))
                    }
                }
                for try await result in group {
                    if let (path, entry) = result { fresh[path] = entry }
                }
            }
            cache = fresh
            saveContentCache(cache)
            entries = fresh.map { path, e in
                ContentEntry(path: path, name: (path as NSString).lastPathComponent,
                             title: e.title, date: e.date, status: e.status,
                             preview: e.preview ?? "", words: e.words ?? 0,
                             scheduled: e.scheduled ?? "",
                             type: e.type ?? "", topic: e.topic ?? "",
                             aiGenerated: e.aiGenerated ?? false,
                             reviewRequired: e.reviewRequired ?? false)
            }
            contentState = .loaded(entries.sorted { $0.date > $1.date }, at: Date())
        } catch {
            contentState = .failed(error.localizedDescription, at: Date())
        }
    }

    func openEntry(_ entry: ContentEntry) async {
        guard let repo = site.repo else { return }
        if let current = editor, current.repoPath == entry.path {
            editorFull = true            // re-enter the room, unsaved work intact
            return
        }
        do {
            let f = try await GitHubAPI.file(repo: repo, path: entry.path)
            guard let text = f.decodedText() else {
                contentState = .failed("Could not decode \(entry.name).", at: Date())
                return
            }
            let doc = EditorDocument(repoPath: entry.path, text: text, sha: f.sha, isNew: false)
            // Crash-safety: offer an autosaved local draft if one differs.
            if let draft = try? String(contentsOf: doc.draftURL, encoding: .utf8), draft != text {
                doc.restoreOffer = draft
                doc.restoreOfferDate = (try? FileManager.default.attributesOfItem(
                    atPath: doc.draftURL.path))?[.modificationDate] as? Date
            }
            attachEditor(doc)
        } catch {
            contentState = .failed(error.localizedDescription, at: Date())
        }
    }

    func newArticle(title: String, inPath dir: String, author: String,
                    template: ArticleTemplate = .blank) {
        let cleanDir = dir.hasSuffix("/") ? dir : dir + "/"
        let file = "\(todayISO())-\(slugify(title)).md"
        let text = newArticleTemplate(title: title, author: author, template: template)
        let doc = EditorDocument(repoPath: cleanDir + file, text: text, sha: nil, isNew: true)
        attachEditor(doc)
        doc.recomputeDirty()
    }

    /// Open a new draft seeded from queue items — see `DraftSeed`.
    ///
    /// The folder is the project's first configured content path, because a
    /// brief that lands somewhere the site does not build is worse than no
    /// brief at all.
    func newDraftFromQueue(clusterKey: String, items: [ReviewQueueItem], author: String) {
        guard !items.isEmpty else { return }
        let dir = site.content_paths?.first ?? "content/articles/"
        let cleanDir = dir.hasSuffix("/") ? dir : dir + "/"
        let today = todayISO()
        let title = DraftSeed.placeholderTitle(clusterKey: clusterKey)
        let file = "\(today)-\(slugify(title)).md"
        let text = DraftSeed.markdown(clusterKey: clusterKey, items: items,
                                      author: author, today: today)
        let doc = EditorDocument(repoPath: cleanDir + file, text: text, sha: nil, isNew: true)
        attachEditor(doc)
        doc.recomputeDirty()
    }

    private func attachEditor(_ doc: EditorDocument) {
        doc.onDirtyChange = { [weak self] d in self?.editorDirty = d }
        doc.startAutosave()
        editor = doc
        editorDirty = doc.dirty
        editorFull = true
        preview.renderNow(doc.bodyText)
    }

    func closeEditor() {
        editor = nil
        editorDirty = false
        SessionHub.shared.state.articlePath = nil
    }

    /// Restore an article by repo path (session restore / dock-open).
    func openPath(_ path: String) async {
        guard let repo = site.repo else { return }
        if let f = try? await GitHubAPI.file(repo: repo, path: path), let text = f.decodedText() {
            let doc = EditorDocument(repoPath: path, text: text, sha: f.sha, isNew: false)
            if let draft = try? String(contentsOf: doc.draftURL, encoding: .utf8), draft != text {
                doc.restoreOffer = draft
                doc.restoreOfferDate = (try? FileManager.default.attributesOfItem(
                    atPath: doc.draftURL.path))?[.modificationDate] as? Date
            }
            attachEditor(doc)
        }
    }
}

// MARK: - Content tab (browser or editor)

struct ContentTabView: View {
    @ObservedObject var model: WorkspaceModel
    var openDeploys: () -> Void

    @EnvironmentObject var chrome: ChromeModel
    @AppStorage("contentListVisible") private var listVisible = true

    var body: some View {
        Group {
            if let doc = model.editor, model.editorFull {
                // Canva-style takeover: the document IS the screen.
                EditorView(model: model, doc: doc, openDeploys: openDeploys,
                           onBack: {
                               withAnimation(.easeInOut(duration: 0.18)) { model.editorFull = false }
                           })
                    .id(doc.id)              // fresh editor (and webview) per document
            } else {
                libraryHome
            }
        }
    }

    /// The library as a Canva-style home: a centered card of all articles.
    private var libraryHome: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 26)
            ContentLibraryView(model: model)
                .frame(maxWidth: 700)
                .background(Color.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.cardBorder))
                .padding(.vertical, 20)
            Spacer(minLength: 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPage)
    }
}

struct ContentLibraryView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var showNewSheet = false
    @State private var pendingOpen: ContentEntry?
    @State private var reviewOnly = false

    private var filtered: [ContentEntry] {
        var list = model.contentEntries
        if reviewOnly {
            list = list.filter { $0.isAIDraft || $0.reviewRequired }
        }
        guard !search.isEmpty else { return list }
        let q = search.lowercased()
        return list.filter {
            $0.title.lowercased().contains(q) || $0.name.lowercased().contains(q)
                || $0.preview.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.textSecondary)
                TextField("Search…", text: $search).textFieldStyle(.plain)
                Toggle(isOn: $reviewOnly) {
                    Text("Review")
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show only AI drafts that still need review")
                if model.contentLoading { ProgressView().controlSize(.mini) }
                Button { Task { await model.refreshEditorial() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(.textSecondary).help("Refresh list + waiting list")
                Button { showNewSheet = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundColor(.accentNavy).help("New article")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if !model.reviewQueue.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").foregroundColor(.statusAmber)
                    Text("\(model.reviewQueue.count) news item\(model.reviewQueue.count == 1 ? "" : "s") on the waiting list — see Overview")
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.navyTint.opacity(0.55))
                Divider()
            }

            if let err = model.contentError {
                VStack {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.stBlocked).font(.caption).padding(.top, 24)
                        .padding(.horizontal, 10)
                    Spacer()
                }
            } else if model.contentEntries.isEmpty && !model.contentLoading {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No articles yet").font(.callout).foregroundColor(.textSecondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(DateBucket.group(filtered), id: \.0) { bucket, rows in
                            Section {
                                ForEach(rows) { entry in
                                    libraryRow(entry)
                                }
                            } header: {
                                HStack {
                                    Text(bucket.uppercased())
                                        .font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                                        .foregroundColor(.textSecondary)
                                    Spacer()
                                    Text("\(rows.count)")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(.textSecondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.bgCard)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color.bgCard)
        .task {
            if model.contentEntries.isEmpty { await model.loadContentList() }
            await model.loadReviewQueue()
        }
        .sheet(isPresented: $showNewSheet) { NewArticleSheet(model: model) }
        .confirmationDialog("Discard unsaved changes?",
                            isPresented: Binding(get: { pendingOpen != nil },
                                                 set: { if !$0 { pendingOpen = nil } })) {
            Button("Switch article", role: .destructive) {
                if let entry = pendingOpen { Task { await model.openEntry(entry) } }
                pendingOpen = nil
            }
            Button("Keep editing", role: .cancel) { pendingOpen = nil }
        } message: {
            Text("Autosave keeps a local draft of your unsaved changes — you can restore it when you come back.")
        }
    }

    private func statusColor(_ entry: ContentEntry) -> Color {
        if entry.isAIDraft { return .statusAmber }
        if entry.isDraft { return .accentNavy }
        if entry.status == "scheduled" { return .statusAmber }
        if entry.status == "published" { return .statusGreen }
        return .cardBorder
    }

    private func libraryRow(_ entry: ContentEntry) -> some View {
        let active = model.editor?.repoPath == entry.path
        return Button {
            guard !active else { return }
            if model.editorDirty { pendingOpen = entry }
            else { Task { await model.openEntry(entry) } }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(statusColor(entry))
                    .frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(active ? .accentNavy : .textPrimary)
                        .lineLimit(1)
                    if entry.isAIDraft {
                        Text(entry.reviewRequired ? "AI Draft · Review Required" : "AI Draft")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.statusAmber)
                    }
                    if !entry.preview.isEmpty {
                        Text(entry.preview)
                            .font(.system(size: 11.5))
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(prettyDate(entry.date))
                        if entry.words > 0 { Text("· \(entry.words) words") }
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(active ? Color.navyTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in New Window") {
                openWindow(id: "article", value: ArticleRef(site: model.site, path: entry.path))
            }
        }
    }
}

struct NewArticleSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var dir: String = ""
    @State private var template: ArticleTemplate = .deepDive

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New article")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder)

            Text("Start from")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textSecondary)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ArticleTemplate.allCases) { t in
                    Button {
                        template = t
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: t.icon)
                                    .foregroundColor(template == t ? .accentNavy : .textSecondary)
                                Text(t.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if template == t {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentNavy).font(.caption)
                                }
                            }
                            Text(t.desc)
                                .font(.caption).foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(template == t ? Color.navyTint : Color.bgPage))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(template == t ? Color.accentNavy : Color.cardBorder))
                    }
                    .buttonStyle(.plain)
                }
            }

            if (model.site.content_paths ?? []).count > 1 {
                Picker("Folder", selection: $dir) {
                    ForEach(model.site.content_paths ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            if !title.isEmpty {
                Text("→ \(todayISO())-\(slugify(title)).md  ·  created as a draft")
                    .font(.system(.caption, design: .monospaced)).foregroundColor(.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create draft") {
                    let folder = dir.isEmpty ? (model.site.content_paths?.first ?? "content/articles/") : dir
                    model.newArticle(title: title, inPath: folder, author: author, template: template)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { dir = model.site.content_paths?.first ?? "" }
    }
}

// MARK: - Editor

enum EditorMode: Int { case editorOnly = 1, split = 2, previewOnly = 3 }

struct EditorView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var doc: EditorDocument
    var openDeploys: () -> Void
    var onBack: (() -> Void)? = nil

    @EnvironmentObject var chrome: ChromeModel
    @StateObject private var wysiwyg = WysiwygController()
    @StateObject private var preview = PreviewController()
    @StateObject private var external = ExternalEditSession()
    @State private var mode: EditorMode = .split
    @AppStorage("contentListVisible") private var listVisible = true
    @State private var showQuality = false
    @State private var dropTargeted = false
    @State private var coverImage: NSImage?
    @State private var showRestore = false
    @AppStorage("typewriterEnabled") private var typewriterOn = true
    @State private var showHistory = false
    @State private var blockEdit: BlockEditContext?
    @State private var showSource = false
    @State private var showLinkPopover = false
    @State private var linkURL = ""
    enum RailPanel { case media, details }
    @State private var railPanel: RailPanel?
    @State private var outline: [(Int, String)] = []
    @AppStorage("editorZoom") private var editorZoom = 1.0

    @State private var showPublish = false
    @State private var scheduleDate = Date().addingTimeInterval(86400)
    @State private var canvaSheet: CanvaSheetContext?
    @State private var canvaBusy = false
    @State private var showConnectHint = false
    @State private var showCanvaPicker = false
    @State private var pendingCanvaEdit: String?

    var body: some View {
        VStack(spacing: 0) {
            if !chrome.focus {
                editorTopBar
                formatBarRow
                Divider()
            }

            if let name = external.activeEditorName {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                        .foregroundColor(.accentNavy)
                    Text("Editing in \(name) — every save there syncs back here (external wins while active).")
                        .font(.caption).foregroundColor(.textPrimary)
                    Spacer()
                    Button("Stop") { external.stop() }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.navyTint)
                Divider()
            }
            HStack(spacing: 0) {
                if !chrome.focus {
                    leftRail
                    Divider()
                    if railPanel == .details {
                        detailsPanel
                            .frame(width: 290)
                            .clipped()
                        Divider()
                    } else if railPanel == .media {
                        MediaPanel(model: model, doc: doc,
                                   onInsert: { path, stem in
                                       wysiwyg.insert(markdown: "![\(stem)](\(path))")
                                   },
                                   onCover: { path in doc.heroImagePath = path; doc.recomputeDirty() },
                                   onUpload: { pickImage { url in Task { await mediaFromFile(url) } } })
                            .frame(width: 250)
                        Divider()
                    }
                }
                VStack(spacing: 0) {
                    if !chrome.focus && mode != .previewOnly {
                        CoverCardView(doc: doc, coverImage: coverImage, busy: canvaBusy,
                                      onChoose: { pickImage { url in Task { await coverFromFile(url) } } },
                                      onCanva: { openCanva(asCover: true) },
                                      onRemove: { doc.heroImagePath = ""; doc.recomputeDirty() },
                                      onDrop: { providers in handleDrop(providers, asCover: true) })
                        Divider()
                    }
                    editorArea
                    if !chrome.focus {
                        Divider()
                        bottomBar
                    }
                }
                if showQuality && !chrome.focus {
                    Divider()
                    QualityPanel(doc: doc, coverImage: coverImage,
                                 articleURL: doc.liveURL(site: model.site.url))
                        .frame(width: 270)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(
            // Keyboard anchors that must survive focus mode hiding the bars.
            Group {
                Button("") { withAnimation(.easeInOut(duration: 0.15)) { chrome.focus.toggle() } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("") {
                    Task {
                        if let repo = model.site.repo {
                            await doc.save(repo: repo)
                            if !doc.dirty { runLiveCheck() }
                        }
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
        .onAppear { wireBridge() }
        .onChange(of: doc.bodyText) { _ in refreshOutline() }
        .onChange(of: chrome.focus) { focused in
            wysiwyg.setTypewriter(focused && typewriterOn)
        }
        .onChange(of: typewriterOn) { on in
            wysiwyg.setTypewriter(chrome.focus && on)
        }
        .task(id: doc.heroImagePath) { await loadCoverThumbnail() }
        .onAppear { if doc.restoreOffer != nil { showRestore = true } }
        .alert("File changed on GitHub since you opened it", isPresented: $doc.conflict) {
            Button("Reload remote version") {
                Task {
                    if let repo = model.site.repo {
                        await doc.reloadRemote(repo: repo)
                        reloadEditorFromBody()
                    }
                }
            }
            Button("Overwrite anyway", role: .destructive) {
                Task { if let repo = model.site.repo { await doc.save(repo: repo, force: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Someone (or Sveltia) committed a newer version of this file. Reload to take the remote version, or overwrite it with your copy.")
        }
        .alert(restoreTitle, isPresented: $showRestore) {
            Button("Restore draft") {
                doc.restoreDraft()
                reloadEditorFromBody()
            }
            Button("Discard draft", role: .destructive) {
                doc.restoreOffer = nil
                doc.clearDraft()
            }
        } message: {
            Text("A locally autosaved version of this article exists (e.g. after a crash). Restore it, or discard and keep the version from GitHub?")
        }
        .onDisappear { external.stop() }
        .navigationTitle(doc.title.isEmpty ? doc.fileName : doc.title)
        .sheet(item: $canvaSheet) { ctx in
            CanvaDesignSheet(context: ctx) { data, name in
                await uploadDropped(data: data, name: name, asCover: ctx.isCover)
                if !ctx.isCover, let path = doc.statusLine?.components(separatedBy: "Image committed: ").last,
                   path.hasPrefix("/") {
                    doc.appendCanvaDesign(id: ctx.id, path: path)
                }
                doc.statusLine = ctx.isCover ? "Cover imported ✓" : "Graphic inserted ✓"
            }
        }
        .onChange(of: mode) { m in SessionHub.shared.state.editorMode = m.rawValue }
        .onChange(of: doc.title) { t in wysiwyg.setDocTitle(t) }

        .alert("Edit this graphic in Canva?", isPresented: Binding(
            get: { pendingCanvaEdit != nil }, set: { if !$0 { pendingCanvaEdit = nil } })) {
            Button("Edit in Canva") {
                if let id = pendingCanvaEdit {
                    Task {
                        if let d = try? await CanvaAPI.design(id: id) {
                            canvaSheet = CanvaSheetContext(id: d.id, editURL: d.editURL, isCover: false)
                        }
                    }
                }
                pendingCanvaEdit = nil
            }
            Button("Cancel", role: .cancel) { pendingCanvaEdit = nil }
        }
        .sheet(isPresented: $showHistory) {
            SnapshotHistorySheet(slug: doc.slug) { text in
                doc.applyFullText(text)
                reloadEditorFromBody()
                doc.statusLine = "Snapshot restored — review and save."
            }
        }
        .sheet(isPresented: $showCanvaPicker) {
            CanvaPickerSheet { item in
                Task { await importExistingDesign(item) }
            }
        }
        .sheet(item: $blockEdit) { ctx in
            BlockEditSheet(context: ctx) { newHTML in
                doc.bodyText = BlockVault.replace(ctx.index, in: doc.bodyText,
                                                  vault: doc.blockVault, with: newHTML)
                doc.recomputeDirty()
                reloadEditorFromBody(reveal: ctx.index)
            }
        }
        .sheet(isPresented: $showSource) {
            SourceSheet(initial: doc.serialized()) { full in
                doc.applyFullText(full)
                reloadEditorFromBody()
            }
        }
        .alert("Connect Canva first", isPresented: $showConnectHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add your Canva Client ID + Secret and press “Connect Canva” in Settings (gear icon).")
        }
    }

    // MARK: Live check (runs after publishing / saving a published article)

    /// Poll the live article page after a deploy-triggering commit and report
    /// what actually went out: HTTP status, empty meta description (the tldr
    /// chain), missing og:image. Results land in the status line + diagnostics.
    private func runLiveCheck() {
        guard let base = model.site.url, case .published = doc.publishState else { return }
        let urlString = doc.liveURL(site: base)
        guard let url = URL(string: urlString) else { return }
        Task {
            doc.statusLine = "Live check: waiting for deploy…"
            let started = Date()
            for attempt in 1...10 {
                try? await Task.sleep(nanoseconds: attempt == 1 ? 20_000_000_000 : 15_000_000_000)
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                req.timeoutInterval = 15
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse else { continue }
                if http.statusCode == 200, let html = String(data: data, encoding: .utf8) {
                    // Only trust a page that already contains this article.
                    guard html.contains(doc.title) || html.contains(doc.slug) else { continue }
                    var warns: [String] = []
                    if html.contains("<meta name=\"description\" content=\"\"") {
                        warns.append("empty description/tldr")
                    }
                    if !html.contains("property=\"og:image\"") { warns.append("no og:image") }
                    let secs = Int(Date().timeIntervalSince(started))
                    doc.statusLine = warns.isEmpty
                        ? "Live ✓ after \(secs)s — description + og:image OK"
                        : "Live after \(secs)s — ⚠ \(warns.joined(separator: ", "))"
                    diagRecord("livecheck", urlString, status: warns.isEmpty ? "ok" : warns.joined(separator: ","),
                               start: started, ok: warns.isEmpty)
                    return
                }
            }
            doc.statusLine = "Live check: page not seen within ~3 min — check Deploys."
            diagRecord("livecheck", urlString, status: "timeout", start: started, ok: false)
        }
    }

    // MARK: Canva design flows

    private func openCanvaPreset(_ preset: CanvaPreset) {
        guard CanvaAuth.shared.isConnected else { showConnectHint = true; return }
        canvaBusy = true
        Task {
            defer { canvaBusy = false }
            do {
                let design = try await CanvaAPI.createDesign(width: preset.size.w, height: preset.size.h,
                                                             title: "\(doc.slug) \(preset.slugSuffix)")
                if preset.isCover {
                    doc.canvaCoverDesign = design.id
                    doc.recomputeDirty()
                }
                canvaSheet = CanvaSheetContext(id: design.id, editURL: design.editURL, isCover: preset.isCover)
            } catch { doc.statusLine = error.localizedDescription }
        }
    }

    private func importExistingDesign(_ item: CanvaDesignItem) async {
        guard CanvaAuth.shared.isConnected else { showConnectHint = true; return }
        doc.uploadingImage = true
        defer { doc.uploadingImage = false }
        do {
            let jobID = try await CanvaAPI.startExport(designID: item.id)
            let url = try await CanvaAPI.waitForExport(jobID: jobID)
            let data = try await CanvaAPI.download(url)
            guard let repo = model.site.repo,
                  let prepared = ImagePipeline.prepare(data: data, suggestedName: (item.title ?? "design") + ".png")
            else { return }
            let path = try await ImagePipeline.upload(repo: repo, slug: doc.slug, prepared: prepared)
            wysiwyg.insert(markdown: "![\(item.title ?? "design")](\(path))")
            doc.appendCanvaDesign(id: item.id, path: path)
            doc.statusLine = "Graphic inserted ✓"
        } catch { doc.statusLine = error.localizedDescription }
    }

    private func openCanva(asCover: Bool) {
        guard CanvaAuth.shared.isConnected else { showConnectHint = true; return }
        canvaBusy = true
        Task {
            defer { canvaBusy = false }
            do {
                if asCover, !doc.canvaCoverDesign.isEmpty {
                    // Re-edit: fetch a fresh edit URL for the stored design.
                    let design = try await CanvaAPI.design(id: doc.canvaCoverDesign)
                    canvaSheet = CanvaSheetContext(id: design.id, editURL: design.editURL, isCover: true)
                } else if asCover {
                    let design = try await CanvaAPI.createDesign(width: 1200, height: 630,
                                                                 title: "\(doc.slug) cover")
                    doc.canvaCoverDesign = design.id
                    doc.recomputeDirty()
                    canvaSheet = CanvaSheetContext(id: design.id, editURL: design.editURL, isCover: true)
                } else {
                    let design = try await CanvaAPI.createDesign(width: 1080, height: 1080,
                                                                 title: "\(doc.slug) graphic")
                    canvaSheet = CanvaSheetContext(id: design.id, editURL: design.editURL, isCover: false)
                }
            } catch {
                doc.statusLine = error.localizedDescription
            }
        }
    }

    private var restoreTitle: String {
        if let d = doc.restoreOfferDate {
            return "Restore unsaved draft from \(relativeTime(ISO8601DateFormatter().string(from: d)))?"
        }
        return "Restore unsaved draft?"
    }

    // MARK: Bridge wiring (bodyText stays the single source the save path uses)

    private func wireBridge() {
        // Blank-line envelope + block vault keep every byte the editor
        // cannot faithfully represent out of its hands.
        let envelope = MarkdownEnvelope.split(doc.bodyText)
        let peeled = BlockVault.peel(doc.bodyText)
        doc.blockVault = peeled.vault
        wysiwyg.onChange = { md in
            let restored = BlockVault.restore(md, vault: doc.blockVault)
            let wrapped = MarkdownEnvelope.rewrap(restored, prefix: envelope.prefix, suffix: envelope.suffix)
            doc.bodyText = wrapped
            doc.recomputeDirty()
            preview.update(markdown: wrapped)
        }
        wysiwyg.onImage = { id, name, data in
            Task { await handleBridgeImage(id: id, name: name, data: data) }
        }
        wysiwyg.onImageMenu = { src in
            if let match = doc.canvaDesigns.first(where: { $0.path == src }) {
                pendingCanvaEdit = match.id
            }
        }
        wysiwyg.onBlockEdit = { i in
            guard i < doc.blockVault.count else { return }
            blockEdit = BlockEditContext(index: i, original: doc.blockVault[i])
        }
        wysiwyg.onBlockDelete = { i in
            guard i < doc.blockVault.count else { return }
            doc.bodyText = BlockVault.replace(i, in: doc.bodyText, vault: doc.blockVault, with: "")
            doc.recomputeDirty()
            reloadEditorFromBody()
        }
        wysiwyg.onBlockInsert = { kind, text in
            if kind == "pullquote", let t = text {
                substituteMarker(with: "<div class=\"pull-quote\">\(t)</div>")
            } else if let k = BlockKind(rawValue: kind) {
                substituteMarker(with: k.markdown)
            } else {
                substituteMarker(with: "")
            }
        }
        wysiwyg.onImagePick = { figurePickFlow() }
        wysiwyg.onTitle = { t in
            if doc.title != t {
                doc.title = t
                doc.recomputeDirty()
            }
        }
        wysiwyg.setDocTitle(doc.title)
        wysiwyg.load(markdown: peeled.display)
        wysiwyg.installBlocks(json: BlockKind.jsPayload)
        preview.renderNow(doc.bodyText)
        SessionHub.shared.state.articlePath = doc.repoPath
        mode = .editorOnly           // Canva rule: one canvas; preview via the eye
        wysiwyg.webView.pageZoom = editorZoom
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { refreshOutline() }
    }

    /// Re-peel the body into the canvas (after block edit/delete/insert,
    /// snapshot restore, conflict reload or external-editor sync).
    private func reloadEditorFromBody(reveal: Int? = nil) {
        let peeled = BlockVault.peel(doc.bodyText)
        doc.blockVault = peeled.vault
        wysiwyg.load(markdown: peeled.display)
        preview.update(markdown: doc.bodyText)
        if let i = reveal { wysiwyg.revealVault(i) }
    }

    /// Raw HTML inserted through the editor API gets backslash-escaped, so
    /// insertion works by marker: the canvas placed a plain-text marker at
    /// the caret; here the current markdown is pulled, vaulted originals are
    /// restored, the marker is swapped for the real block, and the canvas is
    /// re-peeled so the new block appears as a rendered card.
    private func substituteMarker(with block: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            wysiwyg.currentMarkdown { md in
                guard let md = md else { return }
                let envelope = MarkdownEnvelope.split(doc.bodyText)
                let restored = BlockVault.restore(md, vault: doc.blockVault)
                let substituted = BlockVault.substituteMarker(in: restored, with: block)
                doc.bodyText = MarkdownEnvelope.rewrap(substituted, prefix: envelope.prefix, suffix: envelope.suffix)
                doc.recomputeDirty()
                reloadEditorFromBody()
            }
        }
    }

    /// Figure block: marker is already placed — pick an image, upload it,
    /// then swap the marker for a real figure (or remove it on cancel).
    private func figurePickFlow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else {
                substituteMarker(with: "")
                return
            }
            Task { await insertFigure(from: url) }
        }
    }

    private func pickImage(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url { done(url) }
        }
    }

    private func insertFigure(from url: URL) async {
        guard let repo = model.site.repo, let data = try? Data(contentsOf: url) else {
            substituteMarker(with: "")
            return
        }
        doc.uploadingImage = true
        defer { doc.uploadingImage = false }
        guard let prepared = ImagePipeline.prepare(data: data, suggestedName: url.lastPathComponent) else {
            doc.statusLine = "Could not read that image."
            substituteMarker(with: "")
            return
        }
        do {
            let path = try await ImagePipeline.upload(repo: repo, slug: doc.slug, prepared: prepared)
            substituteMarker(with: "<figure>\n<img src=\"\(path)\" alt=\"\">\n<figcaption>Caption.</figcaption>\n</figure>")
            doc.statusLine = "Image committed: \(path)"
        } catch {
            substituteMarker(with: "")
            doc.statusLine = "Image upload failed: \(error.localizedDescription)"
        }
    }

    private func coverFromFile(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        await uploadDropped(data: data, name: url.lastPathComponent, asCover: true)
    }

    private func mediaFromFile(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        await uploadDropped(data: data, name: url.lastPathComponent, asCover: false)
    }

    // MARK: Image pipeline

    private func handleBridgeImage(id: String, name: String, data: Data) async {
        guard let repo = model.site.repo else { return }
        doc.uploadingImage = true
        defer { doc.uploadingImage = false }
        guard let prepared = ImagePipeline.prepare(data: data, suggestedName: name) else {
            doc.statusLine = "Could not read that image."
            return
        }
        do {
            let path = try await ImagePipeline.upload(repo: repo, slug: doc.slug, prepared: prepared)
            wysiwyg.imageUploaded(id: id, path: path)
        } catch {
            doc.statusLine = "Image upload failed: \(error.localizedDescription)"
        }
    }

    private func uploadDropped(data: Data, name: String, asCover: Bool) async {
        guard let repo = model.site.repo else { return }
        doc.uploadingImage = true
        defer { doc.uploadingImage = false }
        guard let prepared = ImagePipeline.prepare(data: data, suggestedName: name) else {
            doc.statusLine = "Could not read that image."
            return
        }
        do {
            let path = try await ImagePipeline.upload(repo: repo, slug: doc.slug, prepared: prepared)
            if asCover {
                doc.heroImagePath = path
                doc.recomputeDirty()
            } else {
                let stem = prepared.filename.components(separatedBy: ".").first ?? "image"
                wysiwyg.insert(markdown: "![\(stem)](\(path))")
            }
            doc.statusLine = "Image committed: \(path)"
        } catch {
            doc.statusLine = "Image upload failed: \(error.localizedDescription)"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], asCover: Bool) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let fileURL = url, let data = try? Data(contentsOf: fileURL) else { return }
                Task { @MainActor in
                    await uploadDropped(data: data, name: fileURL.lastPathComponent, asCover: asCover)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier("public.image") {
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                guard let data = data else { return }
                Task { @MainActor in
                    await uploadDropped(data: data, name: "dropped.png", asCover: asCover)
                }
            }
            return true
        }
        return false
    }

    private func loadCoverThumbnail() async {
        coverImage = nil
        guard let repo = model.site.repo, !doc.heroImagePath.isEmpty else { return }
        let repoPath = doc.heroImagePath.hasPrefix("/") ? String(doc.heroImagePath.dropFirst()) : doc.heroImagePath
        guard let f = try? await GitHubAPI.file(repo: repo, path: repoPath),
              let content = f.content,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return }
        coverImage = NSImage(data: data)
    }

    private func startExternal(_ editor: ExternalEditor) {
        external.start(text: doc.serialized(), slug: doc.slug, editor: editor) { full in
            doc.applyFullText(full)
            reloadEditorFromBody()
        }
    }

    // MARK: Chrome

    /// Canva-style Kopfleiste: navigation, document identity and every
    /// document action live here — the window toolbar stays empty.
    private var editorTopBar: some View {
        HStack(spacing: 11) {
            if let onBack = onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                }
                .buttonStyle(.plain)
                .help("Back to all articles")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title.isEmpty ? doc.fileName : doc.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    publishChip
                    Text(doc.fileName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                    if doc.uploadingImage {
                        ProgressView().controlSize(.mini)
                        Text("Uploading…").font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            Spacer()
            topBarTools
            syncChip
            topBarCommit
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(LinearGradient(colors: [Color(red: 0x17/255, green: 0x2A/255, blue: 0x46/255),
                                            Color.accentNavy],
                                   startPoint: .leading, endPoint: .trailing))
    }

    private var topBarTools: some View {
        HStack(spacing: 2) {
            canvaMenu
            externalMenu
            topIcon("clock.arrow.circlepath", help: "Local history — every save") { showHistory = true }
            topIcon("checklist", active: showQuality, key: "i", help: "Writing-quality panel (⌘I)") {
                withAnimation(.easeInOut(duration: 0.15)) { showQuality.toggle() }
            }
            topIcon(mode == .split ? "eye.fill" : "eye", active: mode == .split, key: "2",
                    help: "Preview next to the document (⌘2)") {
                withAnimation(.easeInOut(duration: 0.15)) { mode = mode == .split ? .editorOnly : .split }
            }
            topIcon("arrow.up.left.and.arrow.down.right", key: "f", focusKey: true,
                    help: "Focus mode (⌘⇧F)") {
                withAnimation(.easeInOut(duration: 0.15)) { chrome.focus.toggle() }
            }
        }
    }

    private var topBarCommit: some View {
        HStack(spacing: 8) {
            Button("Save") {
                Task {
                    if let repo = model.site.repo {
                        await doc.save(repo: repo)
                        if !doc.dirty { runLiveCheck() }
                    }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(doc.saving || model.site.repo == nil)
            .help("Commit the current state (keeps its Draft/Published status) — ⌘S")
            Button {
                scheduleDate = parseISO(doc.scheduledAt) ?? Date().addingTimeInterval(86400)
                showPublish = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                    Text("Publish")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.accentNavy)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPublish, arrowEdge: .bottom) { publishPopover }
            .help("Publish now, schedule, or go back to draft")
        }
    }

    private func topIcon(_ system: String, active: Bool = false, key: Character? = nil, focusKey: Bool = false,
                         help: String, action: @escaping () -> Void) -> some View {
        let btn = Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12.5))
                .foregroundColor(active ? .brandGold : .white.opacity(0.92))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        return Group {
            if let key = key {
                btn.keyboardShortcut(KeyEquivalent(key), modifiers: focusKey ? [.command, .shift] : .command)
            } else {
                btn
            }
        }
    }

    private var canvaMenu: some View {
        Menu {
            ForEach(CanvaPreset.allCases) { preset in
                Button(preset.title) { openCanvaPreset(preset) }
            }
            Divider()
            Button("Open Canva in browser") {
                NSWorkspace.shared.open(URL(string: "https://www.canva.com/")!)
            }
            Button("From my Canva…") {
                if CanvaAuth.shared.isConnected { showCanvaPicker = true } else { showConnectHint = true }
            }
        } label: {
            Image(systemName: "paintbrush")
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.92))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
        .disabled(canvaBusy)
        .help("Canva graphics — presets or your recent designs")
    }

    private var externalMenu: some View {
        Menu {
            ForEach(ExternalEditor.installed()) { editor in
                Button(editor.name) { startExternal(editor) }
            }
            if external.activeEditorName != nil {
                Divider()
                Button("Stop external session") { external.stop() }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 12.5))
                .foregroundColor(external.activeEditorName != nil ? .brandGold : .white.opacity(0.92))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
        .help("Edit in MarkEdit, CotEditor or TextEdit — saves sync back live")
    }

    /// Canva-style left rail: panels and tools that live beside the document.
    private var leftRail: some View {
        VStack(spacing: 4) {
            railButton("plus.square.on.square", label: "Blocks", active: false,
                       help: "Insert a design block at the cursor") { wysiwyg.openGallery() }
            railButton("photo.stack", label: "Media", active: railPanel == .media,
                       help: "This article's images") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    railPanel = railPanel == .media ? nil : .media
                }
            }
            railButton("info.circle", label: "Details", active: railPanel == .details,
                       help: "Date, tags, description, author") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    railPanel = railPanel == .details ? nil : .details
                }
            }
            railButton("chevron.left.forwardslash.chevron.right", label: "Source", active: false,
                       help: "Raw markdown, for fine control") { showSource = true }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 64)
        .background(Color.bgCard)
    }

    private func railButton(_ system: String, label: String, active: Bool,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system)
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(active ? .accentNavy : .textSecondary)
            .frame(width: 56, height: 44)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.navyTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Canva-style bottom bar: outline, stats, zoom.
    private var bottomBar: some View {
        HStack(spacing: 14) {
            Menu {
                if outline.isEmpty {
                    Text("No headings yet")
                } else {
                    ForEach(Array(outline.enumerated()), id: \.offset) { i, h in
                        Button((h.0 == 3 ? "    " : "") + h.1) { wysiwyg.scrollToHeading(i) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.indent").font(.system(size: 10.5))
                    Text("Outline").font(.system(size: 11.5))
                }
                .foregroundColor(.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 92)
            .help("Jump to a section")
            Button {
                typewriterOn.toggle()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 11))
                    .foregroundColor(typewriterOn ? .accentNavy : .textSecondary)
            }
            .buttonStyle(.plain)
            .help("Typewriter scrolling in focus mode")
            Spacer()
            Text(bottomStats)
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
            Spacer()
            HStack(spacing: 6) {
                Button { setZoom(editorZoom - 0.1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).foregroundColor(.textSecondary)
                Text("\(Int((editorZoom * 100).rounded())) %")
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
                    .frame(width: 44)
                Button { setZoom(editorZoom + 0.1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundColor(.textSecondary)
            }
            .help("Document zoom")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.bgCard)
    }

    private var bottomStats: String {
        let words = doc.bodyText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let minutes = max(1, Int((Double(words) / 220.0).rounded(.up)))
        return "\(words) words · \(minutes) min read"
    }

    private func setZoom(_ z: Double) {
        editorZoom = min(1.6, max(0.7, (z * 10).rounded() / 10))
        wysiwyg.webView.pageZoom = editorZoom
    }

    private func refreshOutline() {
        wysiwyg.outline { headings in outline = headings }
    }

    // MARK: Publish flow (Ghost pattern: states + schedule + checklist)

    @ViewBuilder private var publishChip: some View {
        switch doc.publishState {
        case .published:
            Pill(text: "Published", color: .statusGreen)
        case .scheduled(let date):
            Pill(text: "Scheduled · \(prettyDate(date))", color: .statusAmber)
        case .draft:
            Pill(text: "Draft", color: .accentNavy)
        }
    }

    @ViewBuilder private var syncChip: some View {
        Group {
            if doc.saving {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Saving…") }
            } else if doc.dirty {
                HStack(spacing: 5) {
                    Circle().fill(Color.brandGold).frame(width: 7, height: 7)
                    Text("Unsaved")
                }
            } else if let queued = CommitQueue.shared.pending(for: doc.repoPath) {
                HStack(spacing: 4) {
                    Image(systemName: queued.conflicted ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                        .foregroundColor(queued.conflicted ? .statusRed : .statusAmber)
                    Text(queued.conflicted ? "Queue conflict" : "Queued")
                }
                .help(queued.conflicted
                      ? "The queued commit conflicts with a newer remote version — reload and re-apply."
                      : "Committed locally while offline — pushes automatically when online.")
            } else if let sha = doc.lastCommitSHA {
                Button {
                    openDeploys()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.icloud").foregroundColor(.statusGreen)
                        Text(String(sha.prefix(7))).font(.system(.caption, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
                .help("Committed — Netlify builds automatically. Click for deploys.")
            } else {
                Image(systemName: "checkmark.icloud").foregroundColor(.textSecondary)
                    .help(doc.isNewFile ? "New file — saving commits it to \(doc.repoPath)" : "In sync with GitHub")
            }
        }
        .font(.caption)
        .foregroundColor(.textSecondary)
        .help(doc.statusLine ?? "")
    }

    private var publishPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish “\(doc.title.isEmpty ? doc.slug : doc.title)”")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                checkLine(ok: !doc.heroImagePath.isEmpty, "Cover image set")
                checkLine(ok: !doc.descriptionText.isEmpty, "Description present")
                checkLine(ok: !doc.tagsCSV.trimmingCharacters(in: .whitespaces).isEmpty, "At least one tag")
                checkLine(ok: EditorialGate.placeholder(in: doc.bodyText) == nil,
                          EditorialGate.placeholder(in: doc.bodyText).map {
                              "Placeholder text: “\($0)” — the build will refuse this"
                          } ?? "No placeholder text left")
                checkLine(ok: EditorialGate.wordShortfall(body: doc.bodyText, type: doc.articleType) == nil,
                          EditorialGate.wordShortfall(body: doc.bodyText, type: doc.articleType).map {
                              "\($0.words) words — the build floor is \($0.floor)"
                          } ?? "Long enough to publish")
            }
            checkLine(ok: !doc.bodyText.contains("class=\"draft-note\""),
                      doc.bodyText.contains("class=\"draft-note\"")
                          ? "Schema notes present — removed automatically on publish"
                          : "No schema notes left")
            Text("Warnings only — you decide.").font(.caption2).foregroundColor(.textSecondary)

            Divider()

            Button {
                doc.publishNow()
                commitPublish(message: "content: publish \(doc.slug)")
            } label: {
                Label("Publish now", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentNavy)

            HStack(spacing: 8) {
                DatePicker("", selection: $scheduleDate, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
                Button("Schedule") {
                    let iso = isoString(scheduleDate)
                    doc.schedule(iso)
                    commitPublish(message: "content: schedule \(doc.slug) for \(iso)")
                }
            }
            Text("Scheduled = stays a draft until the site’s daily build flips it on the chosen date.")
                .font(.caption2).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .published = doc.publishState {
                Divider()
                Button("Back to draft") {
                    doc.backToDraft()
                    commitPublish(message: "content: unpublish \(doc.slug)")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func checkLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(ok ? .statusGreen : .statusAmber).font(.system(size: 11))
            Text(text).font(.caption)
        }
    }

    private func commitPublish(message: String) {
        showPublish = false
        Task {
            if let repo = model.site.repo {
                await doc.save(repo: repo, message: message)
                if !doc.dirty { runLiveCheck() }
            }
        }
    }


    /// Narrow vertical details panel for the left rail (the old header
    /// form is wide by design and would overflow the column).
    private var detailsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Article details")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .textCase(.uppercase)
                panelField("Title", text: $doc.title, locked: doc.opaqueKeys.contains("title"))
                panelField("Date (YYYY-MM-DD)", text: $doc.dateStr, locked: doc.opaqueKeys.contains("date"))
                panelField("Author", text: $doc.author, locked: doc.opaqueKeys.contains("author"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundColor(.textSecondary)
                    TextEditor(text: $doc.descriptionText)
                        .font(.system(size: 12.5))
                        .frame(height: 74)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
                        .disabled(doc.opaqueKeys.contains("description"))
                }
                panelField("Tags (comma-separated)", text: $doc.tagsCSV, locked: doc.opaqueKeys.contains("tags"))
                Toggle("Draft", isOn: $doc.isDraft)
                    .toggleStyle(.switch)
                    .disabled(doc.opaqueKeys.contains("draft") && doc.opaqueKeys.contains("status"))
                    .help("Draft on = draft: true / status: draft. Off = published.")
                if !doc.opaqueKeys.isEmpty {
                    Text("Locked (complex YAML, preserved untouched): \(doc.opaqueKeys.sorted().joined(separator: ", "))")
                        .font(.caption2).foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .background(Color.bgCard)
        .onChange(of: doc.title) { _ in doc.recomputeDirty() }
        .onChange(of: doc.dateStr) { _ in doc.recomputeDirty() }
        .onChange(of: doc.author) { _ in doc.recomputeDirty() }
        .onChange(of: doc.descriptionText) { _ in doc.recomputeDirty() }
        .onChange(of: doc.tagsCSV) { _ in doc.recomputeDirty() }
        .onChange(of: doc.isDraft) { _ in doc.recomputeDirty() }
    }

    private func panelField(_ label: String, text: Binding<String>, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundColor(.textSecondary)
                if locked { Image(systemName: "lock").font(.system(size: 8)).foregroundColor(.textSecondary) }
            }
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(locked)
        }
    }

    private var frontmatterForm: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    fmField("Title", text: $doc.title, locked: doc.opaqueKeys.contains("title"))
                    HStack(spacing: 10) {
                        fmField("Date", text: $doc.dateStr, locked: doc.opaqueKeys.contains("date"))
                            .frame(width: 140)
                        fmField("Author", text: $doc.author, locked: doc.opaqueKeys.contains("author"))
                            .frame(width: 180)
                        Toggle("Draft", isOn: $doc.isDraft)
                            .toggleStyle(.switch)
                            .disabled(doc.opaqueKeys.contains("draft") && doc.opaqueKeys.contains("status"))
                            .help("Draft on = draft: true / status: draft. Off = published.")
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        fmField("Description", text: $doc.descriptionText, locked: doc.opaqueKeys.contains("description"))
                        fmField("Tags (comma-separated)", text: $doc.tagsCSV, locked: doc.opaqueKeys.contains("tags"))
                    }
                }
                coverWell
            }
            if !doc.opaqueKeys.isEmpty {
                HStack {
                    Text("Locked (complex YAML, preserved untouched): \(doc.opaqueKeys.sorted().joined(separator: ", "))")
                        .font(.caption2).foregroundColor(.textSecondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.bgCard)
        .onChange(of: doc.title) { _ in doc.recomputeDirty() }
        .onChange(of: doc.dateStr) { _ in doc.recomputeDirty() }
        .onChange(of: doc.author) { _ in doc.recomputeDirty() }
        .onChange(of: doc.descriptionText) { _ in doc.recomputeDirty() }
        .onChange(of: doc.tagsCSV) { _ in doc.recomputeDirty() }
        .onChange(of: doc.isDraft) { _ in doc.recomputeDirty() }
    }

    /// Cover-image well: shows the current hero image, accepts a drop to
    /// replace it (same upload pipeline → writes frontmatter hero_image).
    private var coverWell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cover image").font(.caption2.weight(.semibold)).foregroundColor(.textSecondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.bgPage)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(dropTargeted ? Color.accentNavy : Color.cardBorder,
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: coverImage == nil ? [4] : []))
                if let img = coverImage {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 148, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "photo").foregroundColor(.textSecondary)
                        Text(doc.heroImagePath.isEmpty ? "Drop cover here" : "Loading…")
                            .font(.caption2).foregroundColor(.textSecondary)
                    }
                }
            }
            .frame(width: 150, height: 66)
            .onDrop(of: ["public.file-url", "public.image"], isTargeted: $dropTargeted) { providers in
                handleDrop(providers, asCover: true)
            }
            .help(doc.heroImagePath.isEmpty ? "Drop an image to set the cover (hero_image)" : doc.heroImagePath)
            .disabled(doc.opaqueKeys.contains("hero_image"))
            Button {
                openCanva(asCover: true)
            } label: {
                HStack(spacing: 4) {
                    if canvaBusy { ProgressView().controlSize(.mini) }
                    Text(doc.canvaCoverDesign.isEmpty ? "Design cover in Canva" : "Edit cover in Canva")
                }
                .font(.caption2)
            }
            .buttonStyle(.link)
            .disabled(canvaBusy)
        }
    }

    private func fmField(_ label: String, text: Binding<String>, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(.textSecondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(locked)
        }
    }

    @ViewBuilder private var editorArea: some View {
        if chrome.focus {
            // Focus mode: just the writing surface, centered at 720 pt,
            // with a small writing HUD (words · goal ring · typewriter).
            ZStack(alignment: .bottomTrailing) {
                HStack {
                    Spacer(minLength: 0)
                    wysiwygEditor.frame(maxWidth: 720)
                    Spacer(minLength: 0)
                }
                focusHUD
                    .padding(14)
            }
            .background(Color.bgCard)
        } else {
            switch mode {
            case .editorOnly:
                wysiwygEditor
            case .previewOnly:
                WebViewRepresentable(webView: preview.webView)
            case .split:
                HSplitView {
                    wysiwygEditor.frame(minWidth: 340)
                    WebViewRepresentable(webView: preview.webView).frame(minWidth: 320)
                }
            }
        }
    }

    /// The Toast UI WYSIWYG surface (markdown power-mode via its built-in
    /// mode switch). Accepts image drops from Finder / Canva exports.
    private var wysiwygEditor: some View {
        WebViewRepresentable(webView: wysiwyg.webView)
            .onDrop(of: ["public.file-url", "public.image"], isTargeted: .constant(false)) { providers in
                handleDrop(providers, asCover: false)
            }
    }

    /// Canva-style persistent format row under the Kopfleiste.
    private var formatBarRow: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Heading 2") { wysiwyg.exec("heading", payload: ["level": 2]) }
                Button("Heading 3") { wysiwyg.exec("heading", payload: ["level": 3]) }
            } label: {
                Text("Aa").font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
            .help("Paragraph style")

            barDivider
            barButton("B", weight: .bold, help: "Bold") { wysiwyg.exec("bold") }
            barButton("I", italic: true, help: "Italic") { wysiwyg.exec("italic") }
            barIconButton("link", help: "Insert link") { showLinkPopover = true }
                .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        TextField("https://…", text: $linkURL)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .onSubmit { insertLinkFromBar() }
                        Button("Add") { insertLinkFromBar() }
                    }
                    .padding(10)
                }
            barDivider
            barIconButton("quote.opening", help: "Blockquote") { wysiwyg.exec("blockQuote") }
            barIconButton("list.bullet", help: "Bullet list") { wysiwyg.exec("bulletList") }
            barIconButton("list.number", help: "Numbered list") { wysiwyg.exec("orderedList") }
            barDivider
            Button {
                wysiwyg.openGallery()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Block").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(.accentNavy)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .help("Insert a design block")
            barIconButton("photo", help: "Media panel") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    railPanel = railPanel == .media ? nil : .media
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.bgCard)
    }

    private var barDivider: some View {
        Rectangle().fill(Color.cardBorder).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func barButton(_ label: String, weight: Font.Weight = .regular,
                           italic: Bool = false, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: weight))
                .italic(italic)
                .foregroundColor(.textPrimary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func barIconButton(_ system: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12))
                .foregroundColor(.textPrimary)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func insertLinkFromBar() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        showLinkPopover = false
        guard !url.isEmpty else { return }
        wysiwyg.exec("addLink", payload: ["linkUrl": url, "linkText": url])
        linkURL = ""
    }

    private var focusHUD: some View {
        let words = doc.bodyText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let minutes = max(1, Int((Double(words) / 220.0).rounded(.up)))
        return HStack(spacing: 10) {
            if let goal = doc.wordGoal, goal > 0 {
                ZStack {
                    Circle().stroke(Color.cardBorder, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: min(1, CGFloat(words) / CGFloat(goal)))
                        .stroke(words >= goal ? Color.statusGreen : Color.brandGold,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .help("\(words) of \(goal) words (frontmatter word_goal)")
            }
            Text("\(words) words · \(minutes) min")
                .font(.system(size: 11)).foregroundColor(.textSecondary)
            Button {
                typewriterOn.toggle()
            } label: {
                Image(systemName: "text.insert")
                    .foregroundColor(typewriterOn ? .brandNavy : .textSecondary)
            }
            .buttonStyle(.plain)
            .help(typewriterOn ? "Typewriter scrolling on — caret stays centered" : "Typewriter scrolling off")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.bgPage.opacity(0.92)))
        .overlay(Capsule().stroke(Color.cardBorder))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let line = doc.statusLine {
                Text(line).font(.caption).foregroundColor(.textSecondary)
                if doc.lastCommitSHA != nil {
                    Button("Open Deploys →") { openDeploys() }
                        .buttonStyle(.link).font(.caption)
                }
            } else if doc.isNewFile && doc.lastCommitSHA == nil {
                Text("New file — saving commits it to \(doc.repoPath)")
                    .font(.caption).foregroundColor(.textSecondary)
            } else {
                Text(doc.dirty ? "Unsaved changes" : "No changes")
                    .font(.caption).foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}


// MARK: - Cover card (Canva-style visual cover above the canvas)

struct CoverCardView: View {
    @ObservedObject var doc: EditorDocument
    var coverImage: NSImage?
    var busy: Bool
    var onChoose: () -> Void
    var onCanva: () -> Void
    var onRemove: () -> Void
    var onDrop: ([NSItemProvider]) -> Bool

    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        ZStack {
            if let img = coverImage {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: 118)
                        .clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                overlayControls(light: true)
            } else if !doc.heroImagePath.isEmpty {
                Rectangle().fill(Color.navyTint)
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.title3).foregroundColor(.accentNavy)
                    Text(doc.heroImagePath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.textSecondary).lineLimit(1)
                }
                overlayControls(light: false)
            } else {
                Rectangle().fill(Color.bgPage)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundColor(targeted ? .accentNavy : .cardBorder)
                    .padding(10)
                HStack(spacing: 14) {
                    Label("Add a cover", systemImage: "photo.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                    Button("Choose image…", action: onChoose).controlSize(.small)
                    Button {
                        onCanva()
                    } label: {
                        Label(doc.canvaCoverDesign.isEmpty ? "Design in Canva" : "Edit Canva design",
                              systemImage: "paintbrush")
                    }
                    .controlSize(.small).disabled(busy)
                    Text("or drop an image here")
                        .font(.caption).foregroundColor(.textSecondary)
                }
            }
        }
        .frame(height: 118)
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrop(of: ["public.file-url", "public.image"], isTargeted: $targeted) { onDrop($0) }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private func overlayControls(light: Bool) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Text(doc.heroImagePath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(light ? .white.opacity(0.85) : .textSecondary)
                    .lineLimit(1)
                Spacer()
                if hovering {
                    Button("Replace…", action: onChoose).controlSize(.small)
                    Button {
                        onCanva()
                    } label: {
                        Label(doc.canvaCoverDesign.isEmpty ? "Canva" : "Edit in Canva",
                              systemImage: "paintbrush")
                    }
                    .controlSize(.small).disabled(busy)
                    Button("Remove", role: .destructive, action: onRemove).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

// MARK: - Media panel (this article's images)

struct MediaPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var doc: EditorDocument
    var onInsert: (String, String) -> Void
    var onCover: (String) -> Void
    var onUpload: () -> Void

    @State private var items: [GHContentItem] = []
    @State private var loading = true
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textSecondary)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(.textSecondary)
                    .help("Refresh")
                Button(action: onUpload) { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundColor(.accentNavy)
                    .help("Upload an image to this article")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if loading {
                Spacer(); HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }; Spacer()
            } else if items.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3).foregroundColor(.textSecondary)
                    Text(note ?? "No images for this article yet.\nPaste, drop or upload one.")
                        .font(.caption).foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            mediaCell(item)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color.bgCard)
        .task(id: doc.slug) { await load() }
    }

    @ViewBuilder private func mediaCell(_ item: GHContentItem) -> some View {
        let webPath = "/" + item.path
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Rectangle().fill(Color.navyTint)
                if let base = model.site.url, let url = URL(string: base + webPath) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo").foregroundColor(.textSecondary)
                        }
                    }
                }
            }
            .frame(height: 92).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(item.name)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.textSecondary).lineLimit(1)
            HStack(spacing: 6) {
                Button("Insert") {
                    let stem = item.name.components(separatedBy: ".").first ?? "image"
                    onInsert(webPath, stem)
                }
                .controlSize(.small)
                Button("Set as cover") { onCover(webPath) }
                    .controlSize(.small)
                    .disabled(doc.heroImagePath == webPath)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.bgPage))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.cardBorder))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        note = nil
        guard let repo = model.site.repo else { items = []; return }
        do {
            items = try await GitHubAPI.listDir(repo: repo, path: "assets/images/articles/\(doc.slug)")
                .filter { $0.type == "file" }
        } catch {
            items = []
            if case APIError.http(404, _) = error {
                note = "No images for this article yet.\nPaste, drop or upload one."
            } else {
                note = error.localizedDescription
            }
        }
    }
}

// MARK: - Block editor (Canva-style: edit content fields, never markup)

struct BlockEditContext: Identifiable {
    let id = UUID()
    let index: Int
    let original: String
}

struct BlockEditSheet: View {
    let context: BlockEditContext
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind { case pullquote, callout, keyfacts, figure, schemaNote, other }
    @State private var kind: Kind = .other
    @State private var text = ""            // pullquote / callout paragraphs / raw fallback
    @State private var warn = false         // callout flavor
    @State private var title = ""           // keyfacts title
    @State private var itemsText = ""       // keyfacts items, one per line
    @State private var src = ""             // figure
    @State private var alt = ""
    @State private var caption = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(BlockVault.kindLabel(of: context.original))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.textPrimary)
            switch kind {
            case .pullquote:
                Text("The lifted sentence:").font(.caption).foregroundColor(.textSecondary)
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .frame(height: 84)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
            case .callout:
                Picker("Style", selection: $warn) {
                    Text("Info (blue)").tag(false)
                    Text("Warning (amber)").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Text (blank line = new paragraph):").font(.caption).foregroundColor(.textSecondary)
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
            case .keyfacts:
                TextField("Box title", text: $title).textFieldStyle(.roundedBorder)
                Text("One fact per line:").font(.caption).foregroundColor(.textSecondary)
                TextEditor(text: $itemsText)
                    .font(.system(size: 13))
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
            case .schemaNote:
                Text("Guidance for this section (one point per line) — removed automatically on publish:")
                    .font(.caption).foregroundColor(.textSecondary)
                TextEditor(text: $itemsText)
                    .font(.system(size: 13))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
            case .figure:
                LabeledContent("Image") {
                    Text(src.isEmpty ? "—" : src)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.textSecondary).lineLimit(1)
                }
                TextField("Caption", text: $caption).textFieldStyle(.roundedBorder)
                TextField("Alt text (accessibility)", text: $alt).textFieldStyle(.roundedBorder)
            case .other:
                Text("Raw block HTML:").font(.caption).foregroundColor(.textSecondary)
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save block") { onSave(rebuild()); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 470)
        .onAppear { parse() }
    }

    private func parse() {
        let html = context.original
        let inner = Self.innerHTML(of: html)
        if html.contains("class=\"pull-quote\"") {
            kind = .pullquote
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if html.contains("class=\"callout") {
            kind = .callout
            warn = html.contains("callout--warn")
            let paras = Self.matches("<p>([\\s\\S]*?)</p>", inner)
            text = paras.isEmpty ? inner.trimmingCharacters(in: .whitespacesAndNewlines)
                                 : paras.joined(separator: "\n\n")
        } else if html.contains("class=\"keyfacts\"") {
            kind = .keyfacts
            title = Self.matches("<strong>([\\s\\S]*?)</strong>", inner).first ?? "Key facts"
            itemsText = Self.matches("<li>([\\s\\S]*?)</li>", inner).joined(separator: "\n")
        } else if html.contains("class=\"draft-note\"") {
            kind = .schemaNote
            itemsText = Self.matches("<li>([\\s\\S]*?)</li>", html).joined(separator: "\n")
        } else if html.hasPrefix("<figure") {
            kind = .figure
            src = Self.matches("src=\"([^\"]*)\"", html).first ?? ""
            alt = Self.matches("alt=\"([^\"]*)\"", html).first ?? ""
            caption = Self.matches("<figcaption>([\\s\\S]*?)</figcaption>", html).first ?? ""
        } else {
            kind = .other
            text = html
        }
    }

    private func rebuild() -> String {
        switch kind {
        case .pullquote:
            return "<div class=\"pull-quote\">\(text.trimmingCharacters(in: .whitespacesAndNewlines))</div>"
        case .callout:
            let cls = warn ? "callout callout--warn" : "callout callout--info"
            let paras = text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "<p>\($0.replacingOccurrences(of: "\n", with: " "))</p>" }
            return "<div class=\"\(cls)\">\n\(paras.joined(separator: "\n"))\n</div>"
        case .keyfacts:
            let lis = itemsText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "<li>\($0)</li>" }
            return "<div class=\"keyfacts\">\n<p><strong>\(title)</strong></p>\n<ul>\n\(lis.joined(separator: "\n"))\n</ul>\n</div>"
        case .schemaNote:
            let lis = itemsText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "<li>\($0)</li>" }
            return "<div class=\"draft-note\">\n<p><strong>✎ Schema</strong></p>\n<ul>\n\(lis.joined(separator: "\n"))\n</ul>\n</div>"
        case .figure:
            return "<figure>\n<img src=\"\(src)\" alt=\"\(alt)\">\n<figcaption>\(caption)</figcaption>\n</figure>"
        case .other:
            return text
        }
    }

    private static func innerHTML(of block: String) -> String {
        guard let gt = block.firstIndex(of: ">") else { return block }
        let tag = block.hasPrefix("<figure") ? "figure" : "div"
        guard let close = block.range(of: "</\(tag)>", options: .backwards) else { return block }
        return String(block[block.index(after: gt)..<close.lowerBound])
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }
}

// MARK: - Source view (raw markdown, the whole file)

struct SourceSheet: View {
    let initial: String
    var onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Source — full markdown incl. frontmatter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == initial)
            }
            .padding(12)
            Divider()
            PlainTextEditor(text: $text)
                .background(Color.bgPage)
        }
        .frame(width: 720, height: 560)
        .onAppear { text = initial }
    }
}

/// Verbatim source editor: a raw NSTextView with every automatic
/// substitution off. SwiftUI's TextEditor applies macOS smart quotes/dashes,
/// which silently corrupts YAML frontmatter (that is how the FCAS tldr was
/// lost) — a source view must never rewrite bytes.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}


// MARK: - The site's own publish gate, mirrored

/// scripts/editorial-check.js runs as the second step of the Netlify build and
/// calls process.exit(1) on two conditions. Because the build command is an
/// `&&` chain, that aborts everything after it: no articles, no home page, no
/// deploy at all. The site simply freezes at its last good version.
///
/// This app used to check for "text will follow" and "todo". The site checks a
/// longer list. On 17 June 2026 `the-brexit-fail` was published with the body
/// "Text will come soon" — which matches the site's `text will come` and
/// neither of the app's two phrases. The app showed a green tick, the build
/// died, and nothing on the site changed for anyone who was watching.
///
/// So the list lives here verbatim. If scripts/editorial-check.js changes,
/// change this with it — a gate the author cannot see is worse than no gate.
enum EditorialGate {

    /// Mirrors PLACEHOLDER_RE in scripts/editorial-check.js.
    static let placeholderPhrases = [
        "todo", "text folgt", "wird ergänzt", "coming soon",
        "text will come", "text will follow", "text kommt", "halo halo"
    ]

    /// Mirrors MIN_WORDS: briefs and news need 60, everything else 150.
    static let wordFloor = (brief: 60, other: 150)

    /// The offending phrase, or nil when the body is clean.
    nonisolated static func placeholder(in body: String) -> String? {
        let hay = body.lowercased()
        return placeholderPhrases.first { hay.contains($0) }
    }

    nonisolated static func floor(for type: String) -> Int {
        let t = type.lowercased()
        return (t == "brief" || t == "news") ? wordFloor.brief : wordFloor.other
    }

    /// Word count and the floor it misses, or nil when the body is long enough.
    nonisolated static func wordShortfall(body: String, type: String) -> (words: Int, floor: Int)? {
        let n = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let f = floor(for: type)
        return n < f ? (words: n, floor: f) : nil
    }
}
