import SwiftUI
import AppKit


// TEMP-DIAGNOSE
func ldgTrace(_ m: String) {
    let f = "/private/tmp/claude-501/-Users-theoglunz-Desktop-geopolitics-lex/197db9c4-8dc4-49e2-81af-14b963a4eb6c/scratchpad/trace.log"
    let line = m + "\n"
    if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: f, atomically: true, encoding: .utf8) }
}

@main
struct LexCockpitApp: App {
    @NSApplicationDelegateAdaptor(CockpitAppDelegate.self) private var appDelegate
    @StateObject private var store = CockpitStore()

    init() {
        // `swift run LexCockpit --selftest` → run the frontmatter/slug
        // round-trip tests headlessly and exit (used for verification).
        if CommandLine.arguments.contains("--selftest") {
            let a = runFrontmatterSelfTests()
            /* The audit's finding was not "too few tests" — it was that the
               tested parts already worked and the untested four were where
               every bug lived. These cover the two that are pure logic. */
            let b = MainActor.assumeIsolated { runStateSelfTests() }
            /* Und die App auf ihre eigene Zahl festnageln. Der
               Willkommensschirm nennt eine Anzahl gruener Tests; hier
               wird sie gegen die gezaehlte gehalten. Wer einen Test
               hinzufuegt und AppFacts.selftests vergisst, bekommt einen
               roten Lauf statt eines stillen Irrtums. */
            /* Plus eins fuer diese Pruefung selbst. Die Zahl auf dem
               Schirm soll das sein, was jemand nachzaehlt, und das ist
               `--selftest | grep -c PASS`, nicht die Anzahl der
               Behauptungen in den Suiten. */
            let counted = a.passed + b.passed + 1
            let claimOK = counted == AppFacts.selftests
            print(claimOK
                ? "PASS  app: der Willkommensschirm nennt \(AppFacts.selftests) gruene Tests, gezaehlt \(counted)"
                : "FAIL  app: der Willkommensschirm nennt \(AppFacts.selftests) gruene Tests, gezaehlt sind \(counted)")
            exit(a.ok && b.ok && claimOK ? 0 : 1)
        }
        /* `--designcheck <style.css>` liest die echte Datei, meldet, was
           gefunden wurde, und prueft die eine Zusage, auf der der
           Design-Bereich steht: ohne Aenderung kommt die Datei zeichen-
           gleich wieder heraus. Gegen eine Probe im Test zu pruefen ist
           gut, gegen die neuntausend Zeilen der Website ist besser. */
        if let i = CommandLine.arguments.firstIndex(of: "--designcheck"),
           CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            do {
                let css = try String(contentsOfFile: path, encoding: .utf8)
                let sheet = try DesignSheet(css: css, sha: nil)
                let dark = sheet.tokens.filter { $0.dark != nil }.count
                print("Bloecke gefunden : \(sheet.blocksFound) von 3")
                print("Tokens           : \(sheet.tokens.count), davon \(dark) mit Dunkelwert")
                print("Nicht in beiden Dunkel-Bloecken: "
                      + (sheet.darkOutOfSync.isEmpty ? "keine"
                         : sheet.darkOutOfSync.joined(separator: ", ")))
                let same = sheet.rendered() == css
                print(same ? "PASS  unveraendert ist zeichengleich (\(css.count) Zeichen)"
                           : "FAIL  unveraendert ist NICHT zeichengleich")
                /* Und eine Aenderung, um zu sehen, dass wirklich nur sie
                   ankommt. */
                var probe = sheet
                if let k = probe.tokens.firstIndex(where: { $0.name == "muted" }) {
                    let alt = probe.tokens[k].light
                    probe.tokens[k].light = "#5A6070"
                    let out = probe.rendered()
                    /* Nachgelesen statt im Text gesucht: der alte Wert
                       #656C7A steht im Stylesheet auch ausserhalb der
                       Token-Bloecke, und danach zu suchen hiesse, den
                       Rest der Datei mitzupruefen, den wir gerade NICHT
                       anfassen wollen. */
                    let again = try DesignSheet(css: out, sha: nil)
                    let now = again.tokens.first { $0.name == "muted" }?.light
                    let others = zip(sheet.tokens, again.tokens).filter {
                        $0.0.name != "muted" && ($0.0.light != $0.1.light || $0.0.dark != $0.1.dark)
                    }
                    print(now == "#5A6070" && others.isEmpty
                          ? "PASS  nur --muted ist anders (\(alt) -> #5A6070), "
                            + "die anderen \(again.tokens.count - 1) Tokens unveraendert"
                          : "FAIL  die Aenderung kam nicht sauber an")
                }
                exit(same ? 0 : 1)
            } catch {
                print("FEHLER: \(error.localizedDescription)")
                exit(1)
            }
        }
        /* `--rendercheck <site-root>` beweist, dass die Vorschau zeigt,
           was der Deploy baut. Fuer jede Seite in data/pages wird der
           Rumpf hier in Swift gerendert und Zeichen fuer Zeichen mit dem
           verglichen, was der Node-Generator in die Zielseite geschrieben
           hat. Zwei Renderer, die auseinanderdriften, sind eine
           Fehlerquelle mit Ansage; das hier ist der Zaun darum. */
        if let i = CommandLine.arguments.firstIndex(of: "--rendercheck"),
           CommandLine.arguments.indices.contains(i + 1) {
            let root = CommandLine.arguments[i + 1]
            let fm = FileManager.default
            let dir = root + "/data/pages"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
                print("FEHLER: \(dir) nicht lesbar"); exit(1)
            }
            var ok = 0, bad = 0
            for name in names.sorted() where name.hasSuffix(".json") {
                let jsonPath = dir + "/" + name
                guard let json = try? String(contentsOfFile: jsonPath, encoding: .utf8),
                      let page = try? SitePage.parse(path: "data/pages/" + name,
                                                     sha: nil, json: json) else {
                    print("FAIL  \(name): nicht lesbar"); bad += 1; continue
                }
                let targetPath = root + "/" + page.target
                guard let target = try? String(contentsOfFile: targetPath, encoding: .utf8),
                      let a = target.range(of: "<!-- LAYOUT-START -->"),
                      let b = target.range(of: "<!-- LAYOUT-END -->") else {
                    print("FAIL  \(name): Ziel oder Marker fehlt"); bad += 1; continue
                }
                /* Der Generator schreibt Marker, Zeilenumbruch, Rumpf,
                   Zeilenumbruch, vier Leerzeichen, Endmarker. */
                let between = String(target[a.upperBound..<b.lowerBound])
                let fromNode = between
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \n"))
                let fromSwift = BlockRenderer.body(page)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \n"))
                if fromNode == fromSwift {
                    ok += 1
                    print("PASS  \(page.target)  (\(page.blockCount) Bloecke)")
                } else {
                    bad += 1
                    print("FAIL  \(page.target)")
                    let n = Array(fromNode), w = Array(fromSwift)
                    for k in 0..<max(n.count, w.count) where k >= min(n.count, w.count) || n[k] != w[k] {
                        let from = max(0, k - 60)
                        print("      node : " + String(n[from..<min(n.count, k + 60)]))
                        print("      swift: " + String(w[from..<min(w.count, k + 60)]))
                        break
                    }
                }
            }
            print("\n\(ok) gleich, \(bad) abweichend")
            exit(bad == 0 ? 0 : 1)
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
        ldgTrace("App.init fertig")
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
                .onAppear {
                    ldgTrace("ContentView.onAppear")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        ldgTrace("Fenster: " + NSApp.windows.map {
                            "\($0.className) \(Int($0.frame.width))x\(Int($0.frame.height)) vis=\($0.isVisible)"
                        }.joined(separator: " | "))
                    }
                }
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            /* No "New Window": a second copy of the same workspace is
               confusing, and the article windows are the multi window
               story. But the slot cannot stay empty, because with the
               MenuBarExtra keeping the app alive a closed window left no
               way back at all. */
            CommandGroup(replacing: .newItem) {
                Button("Show Workspace") {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.canBecomeMain {
                        if w.isMiniaturized { w.deminiaturize(nil) }
                        w.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateChecker.shared.check(force: true) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
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
        Button("Check for Updates…") {
            Task { await UpdateChecker.shared.check(force: true) }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
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

/* ── One navigation, not two ──────────────────────────────────────────
   Until now the app had a global list of desks (Radar, Tracker, Defence
   and the rest) sitting beside a list of projects, and a separate row of
   section chips inside each project. Two navigations that could disagree
   about where the user was, which is most of what "it does not feel
   thought through" actually means when you sit down and use it.

   There is one site, and every desk is a desk OF that site: the Radar
   watches its feeds, the Tracker tracks the regulations it publishes on.
   So the desks moved inside the project, and what is left at the top
   level is Home and the projects themselves. Everything else is reached
   by opening a project, which is also how the site itself is organised
   and how the user described wanting to work. */

/// Where the sidebar can be. Sections live inside a project now, so they
/// are not cases here: `go(site:tab:)` resolves them to their project.
enum SidebarSelection: Hashable {
    case home
    case site(String)
}

struct ContentView: View {
    @EnvironmentObject var store: CockpitStore
    @ObservedObject private var updates = UpdateChecker.shared
    @StateObject private var chrome = ChromeModel()
    @State private var selection: SidebarSelection? = .home
    @State private var showSettings = false
    @State private var showSwitcher = false
    @State private var showOnboarding = false
    @State private var showWelcome = false
    @State private var welcomeIsFirstRun = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @Environment(\.openWindow) private var openWindow

    /// Flat ⌘1…⌘9: Home, then the projects. Nothing else, because a
    /// shortcut that lands somewhere the sidebar cannot show is how a user
    /// ends up not trusting either.
    private var shortcutOrder: [SidebarSelection] {
        [.home] + store.sites.map { .site($0.id) }
    }

    /// Open a project at one of its sections. This is the only way into a
    /// section now, so every caller goes through it and the sidebar, the
    /// hub and ⌘K can no longer disagree about where the user is.
    private func go(_ site: SiteProject, _ tab: WorkspaceTab) {
        WorkspaceModel.shared(for: site).tab = tab
        selection = .site(site.id)
        SessionHub.shared.state.selectionSite = site.id
        SessionHub.shared.state.selectionSection = nil
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
        .onAppear {
            /* Remember the size and place, but never the fact that there
               were no windows. isRestorable off, autosave on. */
            if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
                w.setFrameAutosaveName("LexCockpitMain")
                w.isRestorable = false
            }
        }
        .sheet(isPresented: $showSwitcher) {
            QuickSwitcherView(store: store, navigate: { sel in selection = sel },
                              openSection: { site, tab in go(site, tab) },
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
            } else if UserDefaults.standard.string(forKey: "lastSeenVersion") != AppVersion.current {
                // Once per version: welcome on the first launch ever,
                // "What's new" after each update. Token onboarding wins.
                welcomeIsFirstRun = UserDefaults.standard.string(forKey: "lastSeenVersion") == nil
                showWelcome = true
            }
        }
        .sheet(isPresented: $showOnboarding) { SettingsSheet(onboarding: true) }
        .sheet(isPresented: $showWelcome) { WelcomeSheet(firstRun: welcomeIsFirstRun) }
        .task {
            restoreSession()                       // instant — local state only
            await store.loadAll()
            await updates.check(force: false)
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
        } else if s.selectionSection != nil {
            /* A section saved by an older build. Those live inside a
               project now, so the name no longer resolves to anything at
               this level. Home is the honest place to land, and the stale
               value is cleared so it cannot puzzle us again. */
            selection = .home
            hub.state.selectionSection = nil
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

    /* The sidebar is the whole navigation now.
     *
     * It used to list three global "Cockpit" sections, then the projects,
     * then a flat list of "Topics" that belonged to no project at all.
     * Clicking a topic took you off the site you were working on; clicking
     * the site handed you a second row of chips. Two navigations, neither
     * aware of the other, which is what made the app feel unplanned.
     *
     * One rule now: the site owns everything. Home lists the projects.
     * Pick one and it opens into its own sections, grouped by what a
     * working day actually does, and the sections that used to be global
     * sit inside it, because they were always readings of that site's own
     * files. */
    /* ── The sidebar ──────────────────────────────────────────────────
       This wants to be a List(selection:) so it inherits arrow keys, the
       system selection and VoiceOver's "selected" trait. It was built
       that way and reverted: on this macOS version a List with a derived
       selection binding inside the split view's sidebar column hung the
       window during restoration, every time, before it appeared. A
       sidebar that answers the arrow keys is worth having; an app that
       does not open is not, so the hand-drawn rows stay until that can be
       done without the hang.

       What did survive from that attempt is the part that mattered most:
       there is now ONE row style, not two. The project row and the
       section rows used to differ in seven measurable ways (bar size,
       icon size, text size, inactive colour, active fill, corner, padding)
       for no reason other than having been written at different times. */
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sideRow(.home, title: "Home", icon: "house")

                eyebrow("Projects").padding(.top, 14)
                if store.sites.isEmpty {
                    Text("No projects yet")
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                } else {
                    ForEach(store.sites) { site in
                        sideRow(.site(site.id), title: site.name,
                                icon: "globe.europe.africa")
                            .contextMenu { siteMenu(site) }
                        if openSiteID == site.id {
                            SiteSectionList(site: site,
                                            model: WorkspaceModel.shared(for: site),
                                            onPick: { tab in go(site, tab) })
                        }
                    }
                }

                Spacer(minLength: 20)
                Text("v\(AppVersion.display)")
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            .padding(.top, 36)          // clear of the traffic lights (hidden title bar)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgCard)
        .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 320)
        .navigationTitle("LexCockpit")
    }

    /// Right-click on a project. The same actions the Home card already
    /// offered, in the place people actually right-click.
    @ViewBuilder private func siteMenu(_ site: SiteProject) -> some View {
        if let u = site.url, let url = URL(string: u) {
            Button("Open website") { NSWorkspace.shared.open(url) }
        }
        if let r = site.repo, let url = URL(string: "https://github.com/" + r) {
            Button("Open repository") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Instruments") { go(site, .tools) }
        Button("Articles") { go(site, .content) }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
    }

    /* One row style for the whole sidebar. Home, a project and a section
       are the same shape at two indents, so nothing in the list looks
       like a different kind of thing than it is. */
    private func sideRow(_ target: SidebarSelection, title: String, icon: String) -> some View {
        let active = selection == target
        return Button {
            switch target {
            case .site(let id):
                if let s = store.sites.first(where: { $0.id == id }) {
                    go(s, WorkspaceModel.shared(for: s).tab)
                }
            case .home:
                selection = .home
                SessionHub.shared.state.selectionSite = nil
                SessionHub.shared.state.selectionSection = nil
            }
        } label: {
            SidebarRowLabel(title: title, icon: icon, active: active, indent: 0)
        }
        .buttonStyle(.plain)
    }

    private var openSiteID: String? {
        if case .site(let id) = selection ?? .home { return id }
        return nil
    }

    /* The list has to OBSERVE the open project's model, or the marked row
       and the panel drift apart the moment anything else changes the
       section (Overview opens an article, Content jumps to Deploys). An
       @ObservedObject cannot be optional, so when nothing is open we hand
       it the first project's model and it simply renders no sections. */
    private var sidebarModelSite: SiteProject {
        if let id = openSiteID, let s = store.sites.first(where: { $0.id == id }) { return s }
        return store.sites.first ?? SiteProject(id: "none", name: "None", url: nil,
                                                cms_url: nil, repo: nil, default_branch: nil,
                                                netlify_site_id: nil, content_paths: nil)
    }

    @ViewBuilder private var detailView: some View {
        switch selection ?? .home {
        case .home:
            ProjectHubView(
                navigate: { target in
                    selection = target
                    if case .site(let id) = target {
                        SessionHub.shared.state.selectionSite = id
                        SessionHub.shared.state.selectionSection = nil
                    }
                },
                openSection: { site, tab in go(site, tab) })
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
    var openSection: (SiteProject, WorkspaceTab) -> Void
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
        /// Extra text matched by the fuzzy filter but not displayed —
        /// keeps filenames searchable once the subtitle shows the
        /// article's date bucket instead.
        var searchExtra: String = ""
        let action: () -> Void
    }

    private var items: [Item] {
        var out: [Item] = []
        for (title, icon, run) in actions {
            out.append(Item(id: "act-" + title, title: title, subtitle: "Action",
                            icon: icon, action: run))
        }
        out.append(Item(id: "sec-home", title: "Home", subtitle: "Section",
                        icon: "square.grid.2x2", action: { navigate(.home) }))
        for site in store.sites {
            out.append(Item(id: "site-" + site.id, title: site.name, subtitle: "Project",
                            icon: "globe", action: { navigate(.site(site.id)) }))
            /* Every section, carrying its project name. "Radar" on its own
               was an address without a place, and with more than one site
               it would have been ambiguous as well as vague. */
            for tab in WorkspaceTab.allCases {
                out.append(Item(id: "sec-\(site.id)-" + tab.rawValue,
                                title: tab.title,
                                subtitle: site.name,
                                icon: tab.icon,
                                searchExtra: site.name + " " + tab.title,
                                action: { openSection(site, tab) }))
            }
            for entry in WorkspaceModel.shared(for: site).contentEntries {
                out.append(Item(id: entry.path, title: entry.title,
                                subtitle: DateBucket.label(for: entry.scheduled.isEmpty
                                                           ? entry.date : entry.scheduled),
                                icon: "doc.text",
                                searchExtra: entry.name,
                                action: { openArticle(site, entry.path) }))
            }
        }
        guard !query.isEmpty else { return out }
        let q = query.lowercased()
        return out.filter {
            fuzzy(q, in: $0.title.lowercased()) || fuzzy(q, in: $0.subtitle.lowercased())
                || (!$0.searchExtra.isEmpty && fuzzy(q, in: $0.searchExtra.lowercased()))
        }
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
                /* Ohne diesen Hinweis schliesst man aus einer leeren
                     Stelle, ein Artikel existiere nicht. */
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
                if items.count > 12 {
                    Text("Showing 12 of \(items.count) matches. Type more to narrow it.")
                        .font(.caption).foregroundColor(.textSecondary)
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


// MARK: - The sections of one project, in the sidebar

/// Observes the project's workspace model so the marked row and the panel
/// on the right can never disagree.

// MARK: - Sidebar rows

/// The one row shape the sidebar uses, at two indents. Home, a project
/// and a section are the same thing to a reader: a place to go.
struct SidebarRowLabel: View {
    let title: String
    let icon: String
    let active: Bool
    /// 0 for a project or Home, 1 for a section inside a project.
    let indent: Int
    var trailingDot: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? Color.accentNavy : Color.clear)
                .frame(width: 3, height: 16)
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
            if trailingDot {
                Circle().fill(Color.brandGold).frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(active ? .accentNavy : .textPrimary)
        .padding(.leading, indent == 0 ? 11 : 24)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? Color.navyTint : Color.clear)
                .padding(.leading, indent == 0 ? 8 : 21)
                .padding(.trailing, 8)
        )
        .contentShape(Rectangle())
    }
}

/// The sections of one project. Observes the project's model, so the
/// marked row and the panel on the right can never disagree.
private struct SiteSectionList: View {
    let site: SiteProject
    @ObservedObject var model: WorkspaceModel
    var onPick: (WorkspaceTab) -> Void

    var body: some View {
        ForEach(WorkspaceTab.Group.allCases) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.textSecondary)
                /* Only Regulation carries a note, and it is the truth:
                   those four panels read EU wide feeds, not this
                   project's files. Saying so in the heading costs one
                   line and saves a reader finding out by confusion. */
                if let note = group.note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(.leading, 27).padding(.top, 10).padding(.bottom, 2)

            ForEach(group.members) { tab in
                Button { onPick(tab) } label: {
                    SidebarRowLabel(title: tab.title, icon: tab.icon,
                                    active: model.tab == tab, indent: 1,
                                    trailingDot: tab == .content && model.editorDirty)
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}

