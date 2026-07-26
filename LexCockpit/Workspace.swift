import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tabs

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, content, cms, design, deploys, repo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .content:  return "Content"
        case .cms:      return "CMS"
        case .design:   return "Design"
        case .deploys:  return "Deploys"
        case .repo:     return "Repo"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .content:  return "doc.text"
        case .cms:      return "globe"
        case .design:   return "paintbrush"
        case .deploys:  return "arrow.up.circle"
        case .repo:     return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Per-site model (cached, survives navigation)

@MainActor
final class WorkspaceModel: ObservableObject {
    let site: SiteProject

    // Deploys
    @Published var deploys: [NetlifyDeploy] = []
    @Published var deploysError: String?
    @Published var deploysLoading = false
    @Published var triggering = false

    // Repo
    @Published var commits: [GHCommit] = []
    @Published var pulls: [GHPull] = []
    @Published var repoError: String?
    @Published var repoLoading = false
    @Published var dataFiles: [GHContentItem] = []

    // Content (browser + editor) — lives here so edits survive tab switches
    @Published var contentEntries: [ContentEntry] = []
    @Published var contentError: String?
    @Published var contentLoading = false
    @Published var editor: EditorDocument?          // nil = browsing
    @Published var editorDirty = false

    let preview = PreviewController()

    private static var cache: [String: WorkspaceModel] = [:]
    static func allOpenEditors() -> [EditorDocument] {
        cache.values.compactMap { $0.editor }
    }
    static func shared(for site: SiteProject) -> WorkspaceModel {
        if let m = cache[site.id] { return m }
        let m = WorkspaceModel(site: site)
        cache[site.id] = m
        return m
    }
    private init(site: SiteProject) { self.site = site }

    // MARK: Deploys

    func loadDeploys() async {
        guard let siteId = site.netlify_site_id, !siteId.isEmpty else {
            deploysError = "No netlify_site_id configured for this project (projects.json)."
            return
        }
        deploysLoading = true
        do {
            deploys = try await NetlifyAPI.deploys(siteId: siteId)
            deploysError = nil
        } catch {
            deploysError = error.localizedDescription
        }
        deploysLoading = false
    }

    func triggerDeploy() async {
        triggering = true
        do {
            try await NetlifyAPI.triggerBuildHook()
            deploysError = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadDeploys()
        } catch {
            deploysError = error.localizedDescription
        }
        triggering = false
    }

    // MARK: Repo

    func loadRepo() async {
        guard let repo = site.repo, !repo.isEmpty else {
            repoError = "No repo configured for this project (projects.json)."
            return
        }
        repoLoading = true
        do {
            async let c = GitHubAPI.commits(repo: repo)
            async let p = GitHubAPI.pulls(repo: repo)
            async let d = GitHubAPI.listDir(repo: repo, path: "data")
            let (cs, ps, ds) = try await (c, p, d)
            commits = cs
            pulls = ps
            dataFiles = ds.filter { $0.type == "file" && $0.name.hasSuffix(".json") }
            repoError = nil
        } catch {
            repoError = error.localizedDescription
        }
        repoLoading = false
    }
}

// MARK: - Workspace view (top bar + tab chips + content)

struct WorkspaceView: View {
    let site: SiteProject
    @StateObject private var model: WorkspaceModel
    @State private var tab: WorkspaceTab = .overview

    init(site: SiteProject) {
        self.site = site
        _model = StateObject(wrappedValue: WorkspaceModel.shared(for: site))
        if let raw = SessionHub.shared.state.workspaceTab, let t = WorkspaceTab(rawValue: raw) {
            _tab = State(initialValue: t)
        }
    }

    @EnvironmentObject var chrome: ChromeModel

    var body: some View {
        VStack(spacing: 0) {
            if !chrome.focus {
                topBar
                Divider()
            }
            content
        }
        .animation(.easeInOut(duration: 0.15), value: tab)
        .animation(.easeInOut(duration: 0.15), value: chrome.focus)
        .background(Color.brandCream)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if let urlStr = site.url, let url = URL(string: urlStr) {
                        Link(urlStr.replacingOccurrences(of: "https://", with: ""), destination: url)
                            .font(.caption)
                    }
                }
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                ForEach(WorkspaceTab.allCases) { t in
                    tabChip(t)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(Color.bgCard)
    }

    @ViewBuilder private var statusPill: some View {
        if let latest = model.deploys.first {
            HStack(spacing: 6) {
                Circle().fill(deployColor(latest.stateKind)).frame(width: 8, height: 8)
                Text(latest.state.capitalized).font(.caption.weight(.semibold))
                    .foregroundColor(.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        } else {
            Pill(text: "Workspace", color: .brandGold.opacity(0.9))
        }
    }

    private func tabChip(_ t: WorkspaceTab) -> some View {
        Button {
            tab = t
            SessionHub.shared.state.workspaceTab = t.rawValue
        } label: {
            HStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 11))
                Text(t.title).font(.system(size: 12, weight: .semibold))
                if t == .content && model.editorDirty {
                    Circle().fill(Color.brandGold).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(tab == t ? Color.brandNavy : Color.primary.opacity(0.05))
            )
            .foregroundColor(tab == t ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewTabView(site: site)
        case .content:  ContentTabView(model: model, openDeploys: { tab = .deploys })
        case .cms:      CMSTabView(site: site)
        case .design:   DesignTabView()
        case .deploys:  DeploysTabView(model: model)
        case .repo:     RepoTabView(model: model)
        }
    }
}

func deployColor(_ kind: String) -> Color {
    switch kind {
    case "good": return .stApplied
    case "bad":  return .stBlocked
    default:     return .stUpcoming
    }
}

// MARK: - Overview tab (the existing editorial pipeline)

struct OverviewTabView: View {
    let site: SiteProject
    @EnvironmentObject var store: CockpitStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: grid(min: 160), spacing: 14) {
                    StatTile(value: "\(store.publishedCount)", label: "Published", accent: .stApplied)
                    StatTile(value: "\(store.draftCount)", label: "In draft", accent: .brandNavy)
                    StatTile(value: "\(store.projects.count)", label: "Total projects", accent: .brandGold)
                }

                HStack {
                    Text("Editorial pipeline")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose the projects.json generated by scripts/build-projects.js"
                        if panel.runModal() == .OK, let url = panel.url {
                            BookmarkStore.store(url, key: BookmarkStore.projectsJSON)
                            store.loadProjects(from: url)
                        }
                    } label: { Label("Open projects.json…", systemImage: "folder") }
                }

                if store.projects.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No projects loaded").fontWeight(.semibold)
                            Text("Run `node scripts/build-projects.js` in your website repo, then open the generated projects.json above.")
                                .foregroundColor(.textSecondary).font(.callout)
                        }
                    }
                } else {
                    LazyVGrid(columns: grid(min: 320), spacing: 14) {
                        ForEach(store.projects) { p in
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        projectPill(p.status)
                                        if let t = p.type { Pill(text: t, color: .brandGold.opacity(0.9)) }
                                        Spacer()
                                        Text(prettyDate(p.scheduledPublishAt ?? p.date))
                                            .font(.caption).foregroundColor(.textSecondary)
                                    }
                                    Text(p.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.textPrimary)
                                    if let topic = p.topic, !topic.isEmpty {
                                        Text(topic).font(.caption).foregroundColor(.textSecondary)
                                    }
                                    if let u = p.url, !u.isEmpty, let url = URL(string: u) {
                                        Link("Open →", destination: url).font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Deploys tab

struct DeploysTabView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var confirmTrigger = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Latest deploys")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if model.deploysLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        Task { await model.loadDeploys() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now (auto-refreshes every 30 s)")
                    Button {
                        confirmTrigger = true
                    } label: {
                        if model.triggering { Text("Triggering…") }
                        else { Label("Trigger deploy", systemImage: "arrow.up.circle.fill") }
                    }
                    .disabled(model.triggering)
                }

                if let err = model.deploysError {
                    Card { Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.stBlocked) }
                }

                if model.deploys.isEmpty && model.deploysError == nil && !model.deploysLoading {
                    Card { Text("No deploys loaded yet.").foregroundColor(.textSecondary) }
                }

                VStack(spacing: 10) {
                    ForEach(model.deploys) { d in
                        Card {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(deployColor(d.stateKind))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.title?.components(separatedBy: "\n").first ?? "(no commit message)")
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text(d.state.capitalized).font(.caption)
                                            .foregroundColor(deployColor(d.stateKind))
                                        if let b = d.branch { Pill(text: b, color: .brandNavy) }
                                        Text(relativeTime(d.created_at)).font(.caption).foregroundColor(.textSecondary)
                                        if let secs = d.deploy_time {
                                            Text("· \(secs)s build").font(.caption).foregroundColor(.textSecondary)
                                        }
                                    }
                                    if let msg = d.error_message, !msg.isEmpty {
                                        Text(msg).font(.caption).foregroundColor(.stBlocked).lineLimit(2)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if model.deploys.isEmpty { await model.loadDeploys() } }
        .onReceive(timer) { _ in Task { await model.loadDeploys() } }
        .alert("Trigger a new deploy?", isPresented: $confirmTrigger) {
            Button("Trigger deploy") { Task { await model.triggerDeploy() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This POSTs your saved Netlify build hook and starts a production build.")
        }
    }
}

// MARK: - Repo tab

struct RepoTabView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var copiedSHA: String?
    @State private var editingFile: GHContentItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Repository")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if let repo = model.site.repo {
                        Link(repo, destination: URL(string: "https://github.com/\(repo)")!)
                            .font(.caption)
                    }
                    if model.repoLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { Task { await model.loadRepo() } } label: { Image(systemName: "arrow.clockwise") }
                }

                if let err = model.repoError {
                    Card { Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.stBlocked) }
                }

                if !model.pulls.isEmpty {
                    Text("Open pull requests")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    VStack(spacing: 8) {
                        ForEach(model.pulls) { pr in
                            Card {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pr.title).fontWeight(.semibold).lineLimit(1)
                                        HStack(spacing: 8) {
                                            Pill(text: "#\(pr.number)", color: .brandNavy)
                                            Text(pr.head.ref).font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if let url = URL(string: pr.html_url) {
                                        Link("Open in Browser →", destination: url).font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }

                Text("Last commits")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                VStack(spacing: 8) {
                    ForEach(model.commits) { c in
                        Card {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.firstLine).fontWeight(.medium).lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text(c.commit.author?.name ?? "—").font(.caption).foregroundColor(.textSecondary)
                                        Text(relativeTime(c.commit.author?.date)).font(.caption).foregroundColor(.textSecondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(c.sha, forType: .string)
                                    copiedSHA = c.sha
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                        if copiedSHA == c.sha { copiedSHA = nil }
                                    }
                                } label: {
                                    Text(copiedSHA == c.sha ? "Copied!" : c.shortSHA)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(copiedSHA == c.sha ? .stApplied : .brandNavy)
                                }
                                .buttonStyle(.plain)
                                .help("Click to copy the full SHA")
                            }
                        }
                    }
                }

                if !model.dataFiles.isEmpty {
                    Text("Quick-edit /data/*.json")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    LazyVGrid(columns: grid(min: 220), spacing: 10) {
                        ForEach(model.dataFiles) { f in
                            Button { editingFile = f } label: {
                                Card {
                                    HStack {
                                        Image(systemName: "curlybraces")
                                        Text(f.name).font(.system(.callout, design: .monospaced)).lineLimit(1)
                                        Spacer()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if model.commits.isEmpty { await model.loadRepo() } }
        .sheet(item: $editingFile) { file in
            JSONQuickEditSheet(model: model, file: file)
        }
    }
}

// MARK: - JSON quick-edit sheet

struct JSONQuickEditSheet: View {
    @ObservedObject var model: WorkspaceModel
    let file: GHContentItem
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var loadedSHA: String?
    @State private var status: String = "Loading…"
    @State private var isValidJSON = true
    @State private var saving = false
    @State private var conflict = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.path).font(.system(.headline, design: .monospaced))
                Spacer()
                if !isValidJSON {
                    Label("Invalid JSON", systemImage: "xmark.octagon").foregroundColor(.stBlocked)
                        .font(.caption)
                }
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : "Commit") { Task { await save(force: false) } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || !isValidJSON || loadedSHA == nil)
            }
            .padding(12)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .onChange(of: text) { newValue in
                    isValidJSON = Self.validate(newValue)
                }
            Divider()
            HStack {
                Text(status).font(.caption).foregroundColor(.textSecondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 780, height: 560)
        .task { await load() }
        .alert("File changed on GitHub since you opened it", isPresented: $conflict) {
            Button("Reload remote version") { Task { await load() } }
            Button("Overwrite anyway", role: .destructive) { Task { await save(force: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    static func validate(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    private func load() async {
        guard let repo = model.site.repo else { return }
        do {
            let f = try await GitHubAPI.file(repo: repo, path: file.path)
            text = f.decodedText() ?? ""
            loadedSHA = f.sha
            isValidJSON = Self.validate(text)
            status = "Loaded — commits go straight to the default branch."
        } catch {
            status = error.localizedDescription
        }
    }

    private func save(force: Bool) async {
        guard let repo = model.site.repo else { return }
        saving = true
        do {
            var sha = loadedSHA
            if force {
                sha = try await GitHubAPI.file(repo: repo, path: file.path).sha
            }
            let resp = try await GitHubAPI.put(
                repo: repo, path: file.path,
                message: "chore(cockpit): edit \(file.name)",
                text: text, sha: sha)
            loadedSHA = resp.content?.sha ?? loadedSHA
            status = "Committed \(String(resp.commit.sha.prefix(7))) ✓"
            await model.loadRepo()
        } catch APIError.conflict {
            conflict = true
        } catch {
            status = error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Settings sheet (all tokens, Keychain only)

struct SettingsSheet: View {
    /// First-run mode: welcome header + "Los geht's" instead of Close.
    var onboarding = false
    @Environment(\.dismiss) private var dismiss
    @State private var tests: [String: String] = [:]
    @State private var testing: Set<String> = []
    @State private var netlifyPAT = ""
    @State private var buildHook = ""
    @State private var githubPAT = ""
    @State private var saved = false
    @State private var feedBaseURL = UserDefaults.standard.string(forKey: "feedBaseURL") ?? ""
    @State private var refreshMinutes = max(UserDefaults.standard.integer(forKey: "refreshMinutes"), 0)
    @State private var canvaID = ""
    @State private var canvaSecret = ""
    @State private var plausibleKey = ""
    @State private var mailerliteKey = ""
    @ObservedObject private var canva = CanvaAuth.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onboarding ? "Welcome to LexCockpit" : "Settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)
            if onboarding {
                Text("One-time setup: paste the keys you have, press Save, then hit each Test button — green means the pipeline works. You can skip anything and add it later via the gear icon.")
                    .font(.callout).foregroundColor(.textSecondary)
            }
            Text("Tokens are stored only in the macOS Keychain — never in files, code or logs.")
                .font(.callout).foregroundColor(.textSecondary)

            field("Netlify personal access token", text: $netlifyPAT,
                  hint: "app.netlify.com → User settings → Applications → New access token",
                  present: Keychain.has(Keychain.netlifyPAT))
            field("Netlify build hook URL", text: $buildHook,
                  hint: "Site configuration → Build & deploy → Build hooks (URL embeds a token)",
                  present: Keychain.has(Keychain.netlifyBuildHook))
            field("GitHub fine-grained PAT", text: $githubPAT,
                  hint: "github.com → Settings → Developer settings → Fine-grained tokens (Contents: read/write)",
                  present: Keychain.has(Keychain.githubPAT))
            testRow("github", "Test GitHub") { await ConnectionTest.github() }
            testRow("netlify", "Test Netlify") { await ConnectionTest.netlify(siteId: nil) }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Canva").font(.callout.weight(.semibold))
                    if canva.connecting {
                        ProgressView().controlSize(.small)
                    } else if canva.needsReconnect {
                        Label("Reconnect needed", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.caption).foregroundColor(.statusAmber)
                    } else if canva.isConnected {
                        Label("Connected as \(canva.displayName ?? "Canva account")",
                              systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundColor(.statusGreen)
                    } else {
                        Text("Not connected").font(.caption).foregroundColor(.textSecondary)
                    }
                    Spacer()
                    if canva.isConnected && !canva.needsReconnect {
                        Button("Disconnect") { canva.disconnect() }
                    } else {
                        Button(canva.needsReconnect ? "Reconnect Canva" : "Connect Canva") {
                            if !canvaID.isEmpty { Keychain.set(Keychain.canvaClientID, canvaID); canvaID = "" }
                            if !canvaSecret.isEmpty { Keychain.set(Keychain.canvaClientSecret, canvaSecret); canvaSecret = "" }
                            Task { await canva.connect() }
                        }
                        .disabled(canva.connecting || (!canva.isConfigured && (canvaID.isEmpty || canvaSecret.isEmpty)))
                    }
                }
                field("Canva Client ID", text: $canvaID,
                      hint: "developer.canva.com → Your integrations (redirect: http://127.0.0.1:8976/callback)",
                      present: Keychain.has(Keychain.canvaClientID))
                field("Canva Client Secret", text: $canvaSecret,
                      hint: "Sign-in opens in your default browser — never inside the app.",
                      present: Keychain.has(Keychain.canvaClientSecret))
                testRow("canva", "Test Canva") { await ConnectionTest.canva() }
                if let err = canva.lastError {
                    Text(err).font(.caption2).foregroundColor(.statusRed)
                        .textSelection(.enabled)
                    if canva.invalidScope {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CanvaAuth.scopeListForCopy, forType: .string)
                        } label: { Label("Copy scope list", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Analytics").font(.callout.weight(.semibold))
                field("Plausible API key", text: $plausibleKey,
                      hint: "plausible.io → Settings → API keys (read-only stats key)",
                      present: Keychain.has(Keychain.plausibleKey))
                field("MailerLite API key", text: $mailerliteKey,
                      hint: "MailerLite → Integrations → API — also enables Weekly-brief drafts",
                      present: Keychain.has(Keychain.mailerliteKey))
                testRow("plausible", "Test Plausible") {
                    await ConnectionTest.plausible(host: "lexdigestglobal.com")
                }
                testRow("mailerlite", "Test MailerLite") { await ConnectionTest.mailerlite() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Feed base URL (override)").font(.callout.weight(.semibold))
                TextField(CockpitStore.defaultBase, text: $feedBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty for the live site. While the site is password-protected you can serve a local copy (`python3 -m http.server 8899` in the website repo) and use http://localhost:8899/data/")
                    .font(.caption2).foregroundColor(.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh interval").font(.callout.weight(.semibold))
                Picker("", selection: $refreshMinutes) {
                    Text("Manual only").tag(0)
                    Text("Every 5 min").tag(5)
                    Text("Every 15 min").tag(15)
                    Text("Every 30 min").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                if saved { Label("Saved to Keychain", systemImage: "checkmark.circle.fill").foregroundColor(.stApplied) }
                Spacer()
                Button(onboarding ? "Los geht's" : "Close") {
                    if onboarding { UserDefaults.standard.set(true, forKey: "onboardedV1") }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if !netlifyPAT.isEmpty { Keychain.set(Keychain.netlifyPAT, netlifyPAT) }
                    if !buildHook.isEmpty { Keychain.set(Keychain.netlifyBuildHook, buildHook) }
                    if !githubPAT.isEmpty { Keychain.set(Keychain.githubPAT, githubPAT) }
                    if !plausibleKey.isEmpty { Keychain.set(Keychain.plausibleKey, plausibleKey) }
                    if !mailerliteKey.isEmpty { Keychain.set(Keychain.mailerliteKey, mailerliteKey) }
                    plausibleKey = ""; mailerliteKey = ""
                    netlifyPAT = ""; buildHook = ""; githubPAT = ""
                    UserDefaults.standard.set(
                        feedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        forKey: "feedBaseURL")
                    UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func testRow(_ id: String, _ label: String,
                         run: @escaping () async -> String) -> some View {
        HStack(spacing: 8) {
            Button {
                testing.insert(id)
                Task {
                    let verdict = await run()
                    tests[id] = verdict
                    testing.remove(id)
                }
            } label: {
                if testing.contains(id) { ProgressView().controlSize(.mini) }
                else { Text(label) }
            }
            .controlSize(.small)
            .disabled(testing.contains(id))
            if let verdict = tests[id] {
                Text(verdict)
                    .font(.caption)
                    .foregroundColor(verdict.hasPrefix("✓") ? .statusGreen : .statusRed)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func field(_ label: String, text: Binding<String>, hint: String, present: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.callout.weight(.semibold))
                if present {
                    Label("stored", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundColor(.stApplied)
                }
            }
            SecureField(present ? "•••••• (leave empty to keep)" : "Paste token…", text: text)
                .textFieldStyle(.roundedBorder)
            Text(hint).font(.caption2).foregroundColor(.textSecondary)
        }
    }
}
