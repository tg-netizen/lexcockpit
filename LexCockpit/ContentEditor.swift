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
        for key in ["title", "date", "author", "description", "draft", "status"] where doc.isOpaque(key) {
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
        // Draft toggle drives whichever fields the file (or template) uses.
        if !opaqueKeys.contains("draft"), doc.scalar("draft") != nil {
            doc.setScalar("draft", isDraft ? "true" : "false")
        }
        if !opaqueKeys.contains("status"), let s = doc.scalar("status") {
            if isDraft, s != "scheduled" { doc.setScalar("status", "draft") }
            if !isDraft { doc.setScalar("status", "published") }
        }
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
            dirty = false
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
            dirty = false
            statusLine = "Reloaded the remote version."
        } catch {
            statusLine = error.localizedDescription
        }
    }
}

// MARK: - Content loading on the workspace model

extension WorkspaceModel {
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
        do {
            for dir in paths {
                let items = try await GitHubAPI.listDir(repo: repo, path: dir)
                    .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
                try await withThrowingTaskGroup(of: ContentEntry?.self) { group in
                    for item in items {
                        group.addTask {
                            guard let text = try await GitHubAPI.file(repo: repo, path: item.path).decodedText()
                            else { return nil }
                            let doc = FrontmatterDoc.parse(text)
                            let status: String
                            if doc.scalar("draft") == "true" || doc.scalar("status") == "draft" { status = "draft" }
                            else if doc.scalar("status") == "scheduled" { status = "scheduled" }
                            else if let s = doc.scalar("status") { status = s }
                            else { status = "—" }
                            return ContentEntry(
                                path: item.path,
                                name: item.name,
                                title: doc.scalar("title") ?? item.name,
                                date: doc.scalar("date") ?? String(item.name.prefix(10)),
                                status: status)
                        }
                    }
                    for try await entry in group where entry != nil {
                        entries.append(entry!)
                    }
                }
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
            attachEditor(EditorDocument(repoPath: entry.path, text: text, sha: f.sha, isNew: false))
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
        editor = doc
        editorDirty = doc.dirty
        preview.renderNow(doc.bodyText)
    }

    func closeEditor() {
        editor = nil
        editorDirty = false
    }
}

// MARK: - Content tab (browser or editor)

struct ContentTabView: View {
    @ObservedObject var model: WorkspaceModel
    var openDeploys: () -> Void

    var body: some View {
        if let doc = model.editor {
            EditorView(model: model, doc: doc, openDeploys: openDeploys)
        } else {
            ContentBrowserView(model: model)
        }
    }
}

struct ContentBrowserView: View {
    @ObservedObject var model: WorkspaceModel
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
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
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
                    Image(systemName: "doc.text").font(.largeTitle).foregroundColor(.secondary)
                    Text("No articles loaded yet").font(.headline)
                    Text("Content is listed from the repo's content_paths via the GitHub API.")
                        .font(.callout).foregroundColor(.secondary)
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
                                    .foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(prettyDate(entry.date)).font(.caption).foregroundColor(.secondary)
                            if entry.isDraft { Pill(text: "Draft", color: .brandNavy) }
                            else if entry.status == "scheduled" { Pill(text: "Scheduled", color: .stUpcoming) }
                            else if entry.status == "published" { Pill(text: "Published", color: .stApplied) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
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
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundColor(.brandNavy)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder)
            if (model.site.content_paths ?? []).count > 1 {
                Picker("Folder", selection: $dir) {
                    ForEach(model.site.content_paths ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            if !title.isEmpty {
                Text("→ \(todayISO())-\(slugify(title)).md  ·  created as a draft")
                    .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
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

    @State private var mode: EditorMode = .split
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            frontmatterForm
            Divider()
            editorArea
            Divider()
            footer
        }
        .alert("File changed on GitHub since you opened it", isPresented: $doc.conflict) {
            Button("Reload remote version") {
                Task { if let repo = model.site.repo { await doc.reloadRemote(repo: repo) } }
            }
            Button("Overwrite anyway", role: .destructive) {
                Task { if let repo = model.site.repo { await doc.save(repo: repo, force: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Someone (or Sveltia) committed a newer version of this file. Reload to take the remote version, or overwrite it with your copy.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard changes", role: .destructive) { model.closeEditor() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if doc.dirty { confirmClose = true } else { model.closeEditor() }
            } label: { Image(systemName: "chevron.left") }
            .help("Back to the article list")

            Text(doc.fileName)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
            if doc.dirty {
                Circle().fill(Color.brandGold).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()

            modeButton(.editorOnly, icon: "square.lefthalf.filled", key: "1", help: "Editor only (⌘1)")
            modeButton(.split, icon: "rectangle.split.2x1", key: "2", help: "Split (⌘2)")
            modeButton(.previewOnly, icon: "square.righthalf.filled", key: "3", help: "Preview only (⌘3)")

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
                .foregroundColor(mode == m ? .brandNavy : .secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help(help)
    }

    private var frontmatterForm: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                fmField("Title", text: $doc.title, locked: doc.opaqueKeys.contains("title"))
            }
            HStack(spacing: 10) {
                fmField("Date", text: $doc.dateStr, locked: doc.opaqueKeys.contains("date"))
                    .frame(width: 150)
                fmField("Author", text: $doc.author, locked: doc.opaqueKeys.contains("author"))
                    .frame(width: 200)
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
            if !doc.opaqueKeys.isEmpty {
                HStack {
                    Text("Locked (complex YAML, preserved untouched): \(doc.opaqueKeys.sorted().joined(separator: ", "))")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: doc.title) { _ in doc.recomputeDirty() }
        .onChange(of: doc.dateStr) { _ in doc.recomputeDirty() }
        .onChange(of: doc.author) { _ in doc.recomputeDirty() }
        .onChange(of: doc.descriptionText) { _ in doc.recomputeDirty() }
        .onChange(of: doc.tagsCSV) { _ in doc.recomputeDirty() }
        .onChange(of: doc.isDraft) { _ in doc.recomputeDirty() }
    }

    private func fmField(_ label: String, text: Binding<String>, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(locked)
        }
    }

    @ViewBuilder private var editorArea: some View {
        switch mode {
        case .editorOnly:
            markdownEditor
        case .previewOnly:
            WebViewRepresentable(webView: model.preview.webView)
        case .split:
            HSplitView {
                markdownEditor.frame(minWidth: 320)
                WebViewRepresentable(webView: model.preview.webView).frame(minWidth: 320)
            }
        }
    }

    private var markdownEditor: some View {
        TextEditor(text: $doc.bodyText)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(2.5)
            .padding(.horizontal, 6)
            .onChange(of: doc.bodyText) { newValue in
                doc.recomputeDirty()
                model.preview.update(markdown: newValue)
            }
            .onAppear { model.preview.renderNow(doc.bodyText) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let line = doc.statusLine {
                Text(line).font(.caption).foregroundColor(.secondary)
                if doc.lastCommitSHA != nil {
                    Button("Open Deploys →") { openDeploys() }
                        .buttonStyle(.link).font(.caption)
                }
            } else if doc.isNewFile && doc.lastCommitSHA == nil {
                Text("New file — saving commits it to \(doc.repoPath)")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(doc.dirty ? "Unsaved changes" : "No changes")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}
