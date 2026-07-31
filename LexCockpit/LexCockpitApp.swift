import SwiftUI
import AppKit

@main
struct LexCockpitApp: App {
    @NSApplicationDelegateAdaptor(CockpitAppDelegate.self) private var appDelegate
    @StateObject private var store = CockpitStore()

    init() {
        // `swift run LexCockpit --selftest` → run the frontmatter/slug
        // round-trip tests headlessly and exit (used for verification).
        if CommandLine.arguments.contains("--selftest") {
            let ok = runFrontmatterSelfTests()
            exit(ok ? 0 : 1)
        }
        // `--roundtrip <dir>` → run the WYSIWYG round-trip data-safety test
        // against real article files (offscreen Toast UI editor) and exit.
        if let i = CommandLine.arguments.firstIndex(of: "--roundtrip"),
           CommandLine.arguments.indices.contains(i + 1) {
            RoundtripTest.start(dir: CommandLine.arguments[i + 1])
        }
        // `--editor-uitest` → functional battery against the real editor
        // shell: gallery/bubble/plus exist, block cards render, insertion
        // produces correct markdown through the vault.
        if CommandLine.arguments.contains("--editor-uitest") {
            EditorUITest.start()
        }
        // `--oauth-callback-test` → start the loopback listener with a known
        // state and wait for one curl; verifies the real OAuth receiver.
        if CommandLine.arguments.contains("--oauth-callback-test") {
            Task {
                do {
                    let code = try await OAuthLoopback.waitForCallback(
                        port: 8976, expectedState: "teststate", timeout: 20)
                    print("CALLBACK code=\(code)")
                    exit(code == "abc123" ? 0 : 1)
                } catch {
                    print("CALLBACK FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        // `--watch-test` → headless check of the external-editor file watcher
        // (in-place writes + atomic replaces, the way real editors save).
        if CommandLine.arguments.contains("--watch-test") {
            Task { @MainActor in
                let ok = await ExternalEditSession.selfTest()
                print(ok ? "WATCH PASS" : "WATCH FAIL")
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        // One-time keychain ownership adoption (kills recurring ACL prompts).
        Keychain.adoptOwnership()
        // Under `swift run` there is no app bundle — promote to a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }

        // Multi-window article editing ("Open in New Window" / dock drops)
        WindowGroup(id: "article", for: ArticleRef.self) { $ref in
            if let ref = ref {
                ArticleWindowView(ref: ref)
                    .frame(minWidth: 860, minHeight: 560)
            }
        }

        // Read-only viewer for .md files dropped from outside any project
        WindowGroup(id: "localmd", for: URL.self) { $url in
            if let url = url { LocalMarkdownWindow(url: url) }
        }

        // Menubar companion: deploy status + radar at a glance, app closed or not.
        MenuBarExtra("LexCockpit", systemImage: "gauge.with.needle") {
            MenubarView().environmentObject(store)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenubarView: View {
    @EnvironmentObject var store: CockpitStore

    var body: some View {
        if let site = store.sites.first {
            let model = WorkspaceModel.shared(for: site)
            if let latest = model.deploys.first {
                Text("Deploy: \(latest.state.capitalized) · \(relativeTime(latest.created_at))")
            } else {
                Text("Deploy status not loaded")
            }
            Button("Check deploys now") { Task { await model.loadDeploys() } }
            Divider()
        }
        let unseen = RadarStore.shared.unseenCount
        Text(unseen > 0 ? "Radar: \(unseen) new change(s)" : "Radar: all caught up")
        Button("Refresh feeds") { Task { await store.loadAll() } }
        Divider()
        Button("Open LexCockpit") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

// MARK: - Article in its own window (independent editor + save path)

struct ArticleWindowView: View {
    let ref: ArticleRef
    @StateObject private var model: WorkspaceModel
    @StateObject private var doc: EditorDocument
    @StateObject private var chrome = ChromeModel()
    @State private var loaded = false

    init(ref: ArticleRef) {
        self.ref = ref
        _model = StateObject(wrappedValue: WorkspaceModel.shared(for: ref.site))
        _doc = StateObject(wrappedValue: EditorDocument(
            repoPath: ref.path, text: "", sha: nil, isNew: false))
    }

    var body: some View {
        Group {
            if loaded {
                EditorView(model: model, doc: doc, openDeploys: {})
            } else {
                ProgressView("Loading \(ref.path)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(chrome)
        .task {
            guard let repo = ref.site.repo,
                  let f = try? await GitHubAPI.file(repo: repo, path: ref.path),
                  let text = f.decodedText() else { return }
            let fresh = EditorDocument(repoPath: ref.path, text: text, sha: f.sha, isNew: false)
            fresh.startAutosave()
            // rebind the StateObject content by copying fields into doc
            doc.adopt(fresh)
            loaded = true
        }
    }
}

struct LocalMarkdownWindow: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundColor(.textSecondary)
                Text(url.lastPathComponent).font(.system(.callout, design: .monospaced))
                Text("· read-only — not inside a configured project")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read file." }
    }
}

enum CockpitSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, radar, analytics, tracker, pipeline, trilogue, enforcement
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:   return "Home"
        case .radar:       return "Radar"
        case .analytics:   return "Analytics"
        case .tracker:     return "Tracker"
        case .pipeline:    return "Pipeline"
        case .trilogue:    return "Trilogue"
        case .enforcement: return "Enforcement"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2"
        case .radar:       return "dot.radiowaves.left.and.right"
        case .analytics:   return "chart.bar"
        case .tracker:     return "calendar"
        case .pipeline:    return "tray.full"
        case .trilogue:    return "person.3"
        case .enforcement: return "eurosign.circle"
        }
    }
}

/// Sidebar selection: a fixed section, or one site workspace.
enum SidebarSelection: Hashable {
    case section(CockpitSection)
    case site(String)
}

struct ContentView: View {
    @EnvironmentObject var store: CockpitStore
    @StateObject private var updates = UpdateChecker()
    @StateObject private var chrome = ChromeModel()
    @State private var selection: SidebarSelection? = .section(.dashboard)
    @State private var showSettings = false
    @State private var showSwitcher = false
    @State private var showOnboarding = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @Environment(\.openWindow) private var openWindow

    /// Flat ⌘1…⌘9 order: Dashboard, then projects, then topics.
    private var shortcutOrder: [SidebarSelection] {
        [.section(.dashboard)]
            + store.sites.map { .site($0.id) }
            + [.section(.tracker), .section(.pipeline), .section(.trilogue), .section(.enforcement)]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                UpdateBanner(checker: updates)
                detailView
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await store.loadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh feeds (⌘R)")
                    .disabled(store.isLoading)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSwitcher = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Jump to anything (⌘K)")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings — tokens (Keychain), refresh, feed URL")
                }
                ToolbarItem(placement: .automatic) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
            }
        }
        .onAppear { NSApp.windows.first?.setFrameAutosaveName("LexCockpitMain") }
        .sheet(isPresented: $showSwitcher) {
            QuickSwitcherView(store: store, navigate: { sel in selection = sel },
                              openArticle: { site, path in
                                  openWindow(id: "article", value: ArticleRef(site: site, path: path))
                              },
                              actions: paletteActions)
        }
        .background(
            Button("") { showSwitcher = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
        .onReceive(NotificationCenter.default.publisher(for: CockpitAppDelegate.openMDNotification)) { note in
            guard let url = note.object as? URL else { return }
            let name = url.lastPathComponent
            for site in store.sites {
                let model = WorkspaceModel.shared(for: site)
                if let entry = model.contentEntries.first(where: { $0.name == name }) {
                    openWindow(id: "article", value: ArticleRef(site: site, path: entry.path))
                    return
                }
                if let dir = site.content_paths?.first, site.repo != nil,
                   url.path.contains("/content/") {
                    openWindow(id: "article", value: ArticleRef(site: site, path: dir + name))
                    return
                }
            }
            openWindow(id: "localmd", value: url)
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "onboardedV1"),
               !Keychain.has(Keychain.githubPAT) {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) { SettingsSheet(onboarding: true) }
        .task {
            restoreSession()                       // instant — local state only
            await store.loadAll()
            await updates.check()
            await RadarStore.shared.load(base: store.feedBase)
            _ = await CommitQueue.shared.flush()
            // Flush queued offline commits once a minute while any exist.
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    if !CommitQueue.shared.items.isEmpty { _ = await CommitQueue.shared.flush() }
                }
            }
            // Background refresh honoring the Settings interval (0 = manual).
            while !Task.isCancelled {
                let minutes = store.refreshMinutes
                if minutes <= 0 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
                guard !Task.isCancelled else { break }
                await store.loadAll()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .background(Color.bgPage)
        .background(sectionShortcuts)
        .environmentObject(chrome)
        .onChange(of: chrome.focus) { focused in
            withAnimation(.easeInOut(duration: 0.15)) {
                columns = focused ? .detailOnly : .automatic
            }
        }
    }

    private var radarRowTitle: String {
        let n = RadarStore.shared.unseenCount
        return n > 0 ? "Radar (\(n))" : "Radar"
    }

    /// Command-palette actions (⌘K) beyond navigation.
    private var paletteActions: [(String, String, () -> Void)] {
        var out: [(String, String, () -> Void)] = [
            ("Refresh feeds", "arrow.clockwise", { Task { await store.loadAll() } }),
            ("Open Settings", "gearshape", { showSettings = true }),
            ("Toggle focus mode", "arrow.up.left.and.arrow.down.right", { chrome.focus.toggle() }),
        ]
        if let site = store.sites.first {
            if let urlStr = site.url, let url = URL(string: urlStr) {
                out.append(("Open site in browser", "safari", { NSWorkspace.shared.open(url) }))
            }
            if let repo = site.repo, let url = URL(string: "https://github.com/\(repo)") {
                out.append(("Open repo on GitHub", "chevron.left.forwardslash.chevron.right",
                            { NSWorkspace.shared.open(url) }))
            }
            out.append(("Go to Deploys", "arrow.up.circle", { selection = .site(site.id) }))
        }
        return out
    }

    /// Restore selection / tab / article from the last session (silent —
    /// openPath fetches a fresh SHA, so conflict logic only ever concerns
    /// unsaved local edits, which autosave covers).
    private func restoreSession() {
        let hub = SessionHub.shared
        defer { hub.flush() }
        let s = hub.state
        if let siteID = s.selectionSite, let site = store.sites.first(where: { $0.id == siteID }) {
            selection = .site(siteID)
            if let path = s.articlePath {
                Task { await WorkspaceModel.shared(for: site).openPath(path) }
            }
        } else if let raw = s.selectionSection, let sec = CockpitSection(rawValue: raw) {
            selection = .section(sec)
        }
    }

    /// Hidden buttons carrying ⌘1…⌘9 for fast section switching.
    private var sectionShortcuts: some View {
        ZStack {
            ForEach(Array(shortcutOrder.prefix(9).enumerated()), id: \.offset) { index, target in
                Button("") { selection = target }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Sidebar (light, eyebrow sections, navy active state)

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                eyebrow("Cockpit")
                sideRow(.section(.dashboard), title: CockpitSection.dashboard.title,
                        icon: CockpitSection.dashboard.icon)
                sideRow(.section(.radar), title: radarRowTitle, icon: CockpitSection.radar.icon)
                sideRow(.section(.analytics), title: CockpitSection.analytics.title,
                        icon: CockpitSection.analytics.icon)

                eyebrow("Projects").padding(.top, 14)
                if store.sites.isEmpty {
                    Text("No projects yet")
                        .font(.caption).foregroundColor(.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                } else {
                    ForEach(store.sites) { site in
                        sideRow(.site(site.id), title: site.name, icon: "globe")
                    }
                }

                eyebrow("Topics").padding(.top, 14)
                ForEach([CockpitSection.tracker, .pipeline, .trilogue, .enforcement]) { s in
                    sideRow(.section(s), title: s.title, icon: s.icon)
                }

                Spacer(minLength: 20)
                Text("v\(AppVersion.display)")
                    .font(.caption2).foregroundColor(.textSecondary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            .padding(.top, 36)          // clear of the traffic lights (hidden title bar)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgCard)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .navigationTitle("LexCockpit")
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
    }

    private func sideRow(_ target: SidebarSelection, title: String, icon: String) -> some View {
        let active = selection == target
        return Button {
            selection = target
            switch target {
            case .site(let id):
                SessionHub.shared.state.selectionSite = id
                SessionHub.shared.state.selectionSection = nil
            case .section(let sec):
                SessionHub.shared.state.selectionSection = sec.rawValue
                SessionHub.shared.state.selectionSite = nil
            }
        } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(active ? Color.accentNavy : .clear)
                    .frame(width: 4, height: 20)
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundColor(active ? .accentNavy : .textSecondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? .accentNavy : .textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.navyTint : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var detailView: some View {
        switch selection ?? .section(.dashboard) {
        case .section(.dashboard):   ProjectHubView(navigate: { target in
            selection = target
            if case .site(let id) = target {
                SessionHub.shared.state.selectionSite = id
                SessionHub.shared.state.selectionSection = nil
            }
        })
        case .section(.radar):       RadarView()
        case .section(.analytics):   AnalyticsView()
        case .section(.tracker):     TrackerView()
        case .section(.pipeline):    PipelineView()
        case .section(.trilogue):    TrilogueView()
        case .section(.enforcement): EnforcementView()
        case .site(let id):
            if let site = store.sites.first(where: { $0.id == id }) {
                WorkspaceView(site: site).id(site.id)
            } else {
                Text("Project not found").foregroundColor(.textSecondary)
            }
        }
    }
}

// MARK: - ⌘K quick switcher (native, fuzzy)

struct QuickSwitcherView: View {
    @ObservedObject var store: CockpitStore
    var navigate: (SidebarSelection) -> Void
    var openArticle: (SiteProject, String) -> Void
    var actions: [(String, String, () -> Void)] = []
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
    }

    private var items: [Item] {
        var out: [Item] = []
        for (title, icon, run) in actions {
            out.append(Item(id: "act-" + title, title: title, subtitle: "Action",
                            icon: icon, action: run))
        }
        for sec in CockpitSection.allCases {
            out.append(Item(id: "sec-" + sec.rawValue, title: sec.title, subtitle: "Section",
                            icon: sec.icon, action: { navigate(.section(sec)) }))
        }
        for site in store.sites {
            out.append(Item(id: "site-" + site.id, title: site.name, subtitle: "Project",
                            icon: "globe", action: { navigate(.site(site.id)) }))
            for entry in WorkspaceModel.shared(for: site).contentEntries {
                out.append(Item(id: entry.path, title: entry.title,
                                subtitle: entry.name, icon: "doc.text",
                                action: { openArticle(site, entry.path) }))
            }
        }
        guard !query.isEmpty else { return out }
        let q = query.lowercased()
        return out.filter { fuzzy(q, in: $0.title.lowercased()) || fuzzy(q, in: $0.subtitle.lowercased()) }
    }

    private func fuzzy(_ needle: String, in hay: String) -> Bool {
        var idx = hay.startIndex
        for ch in needle {
            guard let found = hay[idx...].firstIndex(of: ch) else { return false }
            idx = hay.index(after: found)
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.textSecondary)
                TextField("Jump to project, article or section…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { fire(items.first) }
            }
            .padding(12)
            Divider()
            List {
                ForEach(items.prefix(12)) { item in
                    Button { fire(item) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon).foregroundColor(.accentNavy).frame(width: 18)
                            Text(item.title).foregroundColor(.textPrimary)
                            Spacer()
                            Text(item.subtitle).font(.caption).foregroundColor(.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 360)
        .background(
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        )
    }

    private func fire(_ item: Item?) {
        guard let item = item else { return }
        item.action()
        dismiss()
    }
}
