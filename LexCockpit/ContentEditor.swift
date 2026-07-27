import SwiftUI
import AppKit

// MARK: - Content list entry

struct ContentEntry: Identifiable, Hashable {
    let path: String            // repo path, e.g. content/articles/2026-…-slug.md
    let name: String            // filename
    let title: String
    let date: String
    let status: String          // draft / scheduled / published / —
    var id: String { path }

    var isDraft: Bool { status == "draft" }
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
        for key in ["title", "date", "author", "description", "draft", "status", "hero_image", "canva_cover_design"] where doc.isOpaque(key) {
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
        var doc = fmDoc
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

    func save(repo: String, force: Bool = false) async {
        saving = true
        statusLine = nil
        do {
            var sha = loadedSHA
            if force {
                sha = try await GitHubAPI.file(repo: repo, path: repoPath).sha
            }
            let message = (isNewFile && lastCommitSHA == nil) ? "content: new \(slug)" : "content: edit \(slug)"
            let text = serialized()
            let resp = try await GitHubAPI.put(repo: repo, path: repoPath,
                                               message: message, text: text, sha: sha)
            loadedSHA = resp.content?.sha ?? loadedSHA
            lastCommitSHA = resp.commit.sha
            fmDoc = FrontmatterDoc.parse(text)      // new baseline
            pendingCanvaLines = nil
            dirty = false
            clearDraft()                            // local autosave no longer needed
            statusLine = "Committed \(String(resp.commit.sha.prefix(7))) — Netlify build starts automatically"
        } catch APIError.conflict {
            conflict = true
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
            title = doc.scalar("title") ?? ""
            dateStr = doc.scalar("date") ?? ""
            author = doc.scalar("author") ?? ""
            descriptionText = doc.scalar("description") ?? ""
            tagsCSV = (doc.list("tags") ?? []).joined(separator: ", ")
            isDraft = doc.scalar("draft") == "true" || doc.scalar("status") == "draft"
            bodyText = doc.body
            heroImagePath = doc.scalar("hero_image") ?? ""
            canvaCoverDesign = doc.scalar("canva_cover_design") ?? ""
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
        bodyText = doc.body
        restoreOffer = nil
        recomputeDirty()
        statusLine = "Unsaved draft restored — review and save."
    }
}

// MARK: - Content loading on the workspace model

struct ContentCacheEntry: Codable {
    let sha: String, title: String, date: String, status: String
}

extension WorkspaceModel {
    private var contentCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/content-cache-\(site.id).json")
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
            contentError = "No repo configured for this project (projects.json)."
            return
        }
        let paths = site.content_paths ?? []
        guard !paths.isEmpty else {
            contentError = "No content_paths configured for this project (projects.json)."
            return
        }
        contentLoading = true
        contentError = nil
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
                        if doc.scalar("draft") == "true" || doc.scalar("status") == "draft" { status = "draft" }
                        else if doc.scalar("status") == "scheduled" { status = "scheduled" }
                        else if let s = doc.scalar("status") { status = s }
                        else { status = "—" }
                        return (blob.path, ContentCacheEntry(
                            sha: blob.sha,
                            title: doc.scalar("title") ?? (blob.path as NSString).lastPathComponent,
                            date: doc.scalar("date") ?? String((blob.path as NSString).lastPathComponent.prefix(10)),
                            status: status))
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
                             title: e.title, date: e.date, status: e.status)
            }
            contentEntries = entries.sorted { $0.date > $1.date }
        } catch {
            contentError = error.localizedDescription
        }
        contentLoading = false
    }

    func openEntry(_ entry: ContentEntry) async {
        guard let repo = site.repo else { return }
        do {
            let f = try await GitHubAPI.file(repo: repo, path: entry.path)
            guard let text = f.decodedText() else {
                contentError = "Could not decode \(entry.name)."
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
            contentError = error.localizedDescription
        }
    }

    func newArticle(title: String, inPath dir: String, author: String) {
        let cleanDir = dir.hasSuffix("/") ? dir : dir + "/"
        let file = "\(todayISO())-\(slugify(title)).md"
        let text = newArticleTemplate(title: title, author: author)
        let doc = EditorDocument(repoPath: cleanDir + file, text: text, sha: nil, isNew: true)
        attachEditor(doc)
        doc.recomputeDirty()
    }

    private func attachEditor(_ doc: EditorDocument) {
        doc.onDirtyChange = { [weak self] d in self?.editorDirty = d }
        doc.startAutosave()
        editor = doc
        editorDirty = doc.dirty
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

    var body: some View {
        if let doc = model.editor {
            EditorView(model: model, doc: doc, openDeploys: openDeploys)
                .id(doc.id)                      // fresh editor (and webview) per document
        } else {
            ContentBrowserView(model: model)
        }
    }
}

struct ContentBrowserView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var showNewSheet = false

    private var filtered: [ContentEntry] {
        guard !search.isEmpty else { return model.contentEntries }
        let q = search.lowercased()
        return model.contentEntries.filter {
            $0.title.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.textSecondary)
                TextField("Search by title or filename…", text: $search)
                    .textFieldStyle(.plain)
                if model.contentLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await model.loadContentList() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh list")
                Button { showNewSheet = true } label: { Label("New article", systemImage: "plus") }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if let err = model.contentError {
                VStack {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.stBlocked)
                        .padding(.top, 30)
                    Spacer()
                }
            } else if model.contentEntries.isEmpty && !model.contentLoading {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text").font(.largeTitle).foregroundColor(.textSecondary)
                    Text("No articles loaded yet").font(.headline)
                    Text("Content is listed from the repo's content_paths via the GitHub API.")
                        .font(.callout).foregroundColor(.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filtered) { entry in
                    Button { Task { await model.openEntry(entry) } } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).fontWeight(.medium).lineLimit(1)
                                Text(entry.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Text(prettyDate(entry.date)).font(.caption).foregroundColor(.textSecondary)
                            if entry.isDraft { Pill(text: "Draft", color: .brandNavy) }
                            else if entry.status == "scheduled" { Pill(text: "Scheduled", color: .stUpcoming) }
                            else if entry.status == "published" { Pill(text: "Published", color: .stApplied) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Open in New Window") {
                            openWindow(id: "article", value: ArticleRef(site: model.site, path: entry.path))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { if model.contentEntries.isEmpty { await model.loadContentList() } }
        .sheet(isPresented: $showNewSheet) { NewArticleSheet(model: model) }
    }
}

struct NewArticleSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var dir: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New article")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder)
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
                    model.newArticle(title: title, inPath: folder, author: author)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { dir = model.site.content_paths?.first ?? "" }
    }
}

// MARK: - Editor

enum EditorMode: Int { case editorOnly = 1, split = 2, previewOnly = 3 }

struct EditorView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var doc: EditorDocument
    var openDeploys: () -> Void

    @EnvironmentObject var chrome: ChromeModel
    @StateObject private var wysiwyg = WysiwygController()
    @StateObject private var preview = PreviewController()
    @State private var mode: EditorMode = .split
    @State private var confirmClose = false
    @State private var showQuality = false
    @State private var dropTargeted = false
    @State private var coverImage: NSImage?
    @State private var showRestore = false
    @State private var canvaSheet: CanvaSheetContext?
    @State private var canvaBusy = false
    @State private var showConnectHint = false
    @State private var showCanvaPicker = false
    @State private var pendingCanvaEdit: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !chrome.focus {
                frontmatterForm
                Divider()
            }
            HStack(spacing: 0) {
                editorArea
                if showQuality && !chrome.focus {
                    Divider()
                    QualityPanel(doc: doc, coverImage: coverImage,
                                 articleURL: (model.site.url ?? "") + "/articles/" + doc.slug + ".html")
                        .frame(width: 270)
                        .transition(.move(edge: .trailing))
                }
            }
            if !chrome.focus {
                Divider()
                footer
            }
        }
        .onAppear { wireBridge() }
        .task(id: doc.heroImagePath) { await loadCoverThumbnail() }
        .onAppear { if doc.restoreOffer != nil { showRestore = true } }
        .alert("File changed on GitHub since you opened it", isPresented: $doc.conflict) {
            Button("Reload remote version") {
                Task {
                    if let repo = model.site.repo {
                        await doc.reloadRemote(repo: repo)
                        wysiwyg.load(markdown: doc.bodyText)
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
                wysiwyg.load(markdown: doc.bodyText)
            }
            Button("Discard draft", role: .destructive) {
                doc.restoreOffer = nil
                doc.clearDraft()
            }
        } message: {
            Text("A locally autosaved version of this article exists (e.g. after a crash). Restore it, or discard and keep the version from GitHub?")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard changes", role: .destructive) { model.closeEditor() }
            Button("Keep editing", role: .cancel) {}
        }
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
        .sheet(isPresented: $showCanvaPicker) {
            CanvaPickerSheet { item in
                Task { await importExistingDesign(item) }
            }
        }
        .alert("Connect Canva first", isPresented: $showConnectHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add your Canva Client ID + Secret and press “Connect Canva” in Settings (gear icon).")
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
        // Preserve the body's blank-line envelope so an unedited document
        // stays byte-identical through the WYSIWYG surface.
        let envelope = MarkdownEnvelope.split(doc.bodyText)
        wysiwyg.onChange = { md in
            let wrapped = MarkdownEnvelope.rewrap(md, prefix: envelope.prefix, suffix: envelope.suffix)
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
        wysiwyg.load(markdown: doc.bodyText)
        wysiwyg.installBlocks(json: BlockKind.jsPayload)
        preview.renderNow(doc.bodyText)
        SessionHub.shared.state.articlePath = doc.repoPath
        if let raw = SessionHub.shared.state.editorMode, let m = EditorMode(rawValue: raw) { mode = m }
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

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if doc.dirty { confirmClose = true } else { model.closeEditor() }
            } label: { Image(systemName: "chevron.left") }
            .help("Back to the article list")

            Text(doc.fileName)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.textSecondary)
            if doc.dirty {
                Circle().fill(Color.brandGold).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            if doc.uploadingImage {
                ProgressView().controlSize(.small)
                Text("Uploading image…").font(.caption).foregroundColor(.textSecondary)
            }
            Spacer()

            Menu {
                ForEach(BlockKind.allCases) { block in
                    Button {
                        wysiwyg.insert(markdown: block.markdown)
                    } label: { Label(block.title, systemImage: block.icon) }
                }
            } label: {
                Image(systemName: "plus.square")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("Insert block (or type “/” on an empty line)")

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
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .disabled(canvaBusy)
            .help("Canva graphics — presets or your recent designs")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { chrome.focus.toggle() }
            } label: {
                Image(systemName: chrome.focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .foregroundColor(chrome.focus ? .brandNavy : .textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus mode (⌘⇧F)")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showQuality.toggle() }
            } label: {
                Image(systemName: "checklist")
                    .foregroundColor(showQuality ? .brandNavy : .textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
            .help("Writing-quality panel (⌘I)")

            modeButton(.editorOnly, icon: "square.and.pencil", key: "1", help: "Editor only (⌘1)")
            modeButton(.split, icon: "rectangle.split.2x1", key: "2", help: "Editor + preview (⌘2)")
            modeButton(.previewOnly, icon: "doc.richtext", key: "3", help: "Preview only (⌘3)")

            Button {
                Task { if let repo = model.site.repo { await doc.save(repo: repo) } }
            } label: {
                doc.saving ? Text("Saving…") : Text("Save  ⌘S")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(doc.saving || model.site.repo == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func modeButton(_ m: EditorMode, icon: String, key: KeyEquivalent, help: String) -> some View {
        Button { mode = m } label: {
            Image(systemName: icon)
                .foregroundColor(mode == m ? .brandNavy : .textSecondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help(help)
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
            // Focus mode: just the writing surface, centered at 720 pt.
            HStack {
                Spacer(minLength: 0)
                wysiwygEditor.frame(maxWidth: 720)
                Spacer(minLength: 0)
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
