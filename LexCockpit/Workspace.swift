import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tabs

/* The sections a site offers.
 *
 * These used to be chips in a bar above the workspace, while the sidebar
 * carried a separate, global list of "Topics". That was two navigations
 * that did not know about each other: a topic took you off the site, and
 * a site handed you a second bar. There is one navigation now, the
 * sidebar, and the site owns it. The chips are gone.
 *
 * `group` is what the sidebar uses to headline them, so the order below
 * is the order a working day tends to take: look, write, watch, ship. */
/* ── The sections of a project ─────────────────────────────────────────
   The grouping is not an invented taxonomy. lexdigestglobal.com has four
   desks in its own nav.json, in this order: News, Regulation, Sanctions,
   Defence. Those four are the middle of this list, spelled the same way
   and ordered the same way, so that opening the app and opening the site
   put you in front of the same furniture.

   The groups around them are the parts of the work the website does not
   have a desk for: the project itself and its instruments at the top,
   publishing at the bottom. They are named for what they do, not for a
   workflow metaphor. The previous names (Make, Watch, Desks, Ship) came
   from a general idea of work rather than from this site, which is why
   nothing in them could be found by someone who knows the site. */
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, tools, radar, analytics
    case content, planner
    case tracker, pipeline, trilogue, enforcement
    case sanctions
    case defence
    case cms, deploys, repo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:    return "Overview"
        case .tools:       return "Instruments"
        case .radar:       return "Radar"
        case .analytics:   return "Analytics"
        case .content:     return "Articles"
        case .planner:     return "Calendar"
        case .tracker:     return "Deadlines"
        case .pipeline:    return "Pipeline"
        case .trilogue:    return "Trilogue"
        case .enforcement: return "Enforcement"
        case .sanctions:   return "Dossiers"
        case .defence:     return "Defence"
        case .cms:         return "CMS"
        case .deploys:     return "Deploys"
        case .repo:        return "Repo"
        }
    }

    /* No symbol appears twice. Three used to: Home and Overview both drew
       square.grid.2x2, the project row and CMS both drew globe, and the two
       calendars differed only by a badge. A symbol that means two things is
       worse than no symbol, because it is read faster than the label. */
    var icon: String {
        switch self {
        case .overview:    return "rectangle.3.group"
        case .tools:       return "wrench.and.screwdriver"
        case .radar:       return "dot.radiowaves.left.and.right"
        case .analytics:   return "chart.bar"
        case .content:     return "doc.text"
        case .planner:     return "calendar.day.timeline.left"
        case .tracker:     return "calendar.badge.clock"
        case .pipeline:    return "tray.full"
        case .trilogue:    return "person.3"
        case .enforcement: return "eurosign.circle"
        case .sanctions:   return "hand.raised"
        case .defence:     return "shield.lefthalf.filled"
        case .cms:         return "square.and.pencil.circle"
        case .deploys:     return "arrow.up.circle"
        case .repo:        return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// True where the section reads site-wide EU data rather than this
    /// project's own. Sitting under a project it would otherwise promise
    /// something it does not deliver, so the group heading says so.
    var isSiteWide: Bool {
        switch self {
        case .tracker, .pipeline, .trilogue, .enforcement: return true
        default: return false
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        /// The project and the instruments that describe it.
        case project
        /// The four desks of lexdigestglobal.com, in the site's own order.
        case news, regulation, sanctions, defence
        /// Getting it out.
        case publish

        var id: String { rawValue }

        var title: String {
            switch self {
            case .project:    return "Project"
            case .news:       return "News"
            case .regulation: return "Regulation"
            case .sanctions:  return "Sanctions"
            case .defence:    return "Defence"
            case .publish:    return "Publish"
            }
        }

        /// Shown under the heading where the group needs a caveat. Only
        /// Regulation has one, and it is the truth: those four panels read
        /// EU-wide feeds, not this project's files.
        var note: String? {
            self == .regulation ? "EU wide, not per project" : nil
        }

        /// True for the four groups that mirror a desk on the website.
        var isSiteDesk: Bool {
            switch self {
            case .news, .regulation, .sanctions, .defence: return true
            case .project, .publish: return false
            }
        }

        var members: [WorkspaceTab] {
            switch self {
            case .project:    return [.overview, .tools, .radar, .analytics]
            case .news:       return [.content, .planner]
            case .regulation: return [.tracker, .pipeline, .trilogue, .enforcement]
            case .sanctions:  return [.sanctions]
            case .defence:    return [.defence]
            case .publish:    return [.cms, .deploys, .repo]
            }
        }
    }
}

// MARK: - Per-site model (cached, survives navigation)

@MainActor
final class WorkspaceModel: ObservableObject {
    let site: SiteProject

    /// Canva-style editor takeover: when true the Content section shows
    /// ONLY the document editor, without the library column.
    @Published var editorFull = false

    /* The active section. It lives on the model rather than in the view
       because the sidebar sets it now, and a @State in the view could not
       hear that. Persisted, so the app reopens where it was left. */
    @Published var tab: WorkspaceTab = .overview {
        didSet {
            guard tab != oldValue else { return }
            SessionHub.shared.state.workspaceTab = tab.rawValue
            SessionHub.shared.flush()
        }
    }

    // Deploys
    /* One state instead of three fields. The old triple could not say
       "not asked yet", and an empty array read as "there is nothing" —
       see LoadState.swift for the morning that cost. The computed
       accessors keep every existing view compiling unchanged. */
    @Published var deploysState: LoadState<[NetlifyDeploy]> = .never
    var deploys: [NetlifyDeploy] { deploysState.value ?? [] }
    var deploysError: String? { deploysState.error }
    var deploysLoading: Bool { deploysState.isLoading }
    @Published var triggering = false

    // Repo
    @Published var repoState: LoadState<[GHCommit]> = .never
    var commits: [GHCommit] { repoState.value ?? [] }
    @Published var pulls: [GHPull] = []
    var repoError: String? { repoState.error }
    var repoLoading: Bool { repoState.isLoading }
    @Published var dataFiles: [GHContentItem] = []

    /* ── Tools ────────────────────────────────────────────────────────
       The register of instruments the site carries. Derived from the repo
       on demand rather than stored, because a hand-kept list of tools is a
       list that goes stale the first busy week, and a stale list is worse
       than none: it reads as coverage. */
    @Published var toolsState: LoadState<[SiteTool]> = .never
    var tools: [SiteTool] { toolsState.value ?? [] }
    var toolsError: String? { toolsState.error }
    var toolsLoading: Bool { toolsState.isLoading }
    /// How much of the repo the last scan actually read, so the header can
    /// say what its numbers rest on instead of implying completeness.
    @Published var toolsScanned = ToolScanScope(scripts: 0, pages: 0)

    /* ── Sanctions dossiers ───────────────────────────────────────────
       The website carries a Sanctions desk with a country dossier per
       regime. The app had no counterpart at all, so the desk was simply
       missing from the workspace. This is the honest first step: not an
       editor, but the actual stock, counted from the repo and openable. */
    @Published var dossiersState: LoadState<[SiteDossier]> = .never
    var dossiers: [SiteDossier] { dossiersState.value ?? [] }
    var dossiersError: String? { dossiersState.error }
    var dossiersLoading: Bool { dossiersState.isLoading }

    // Content (browser + editor) — lives here so edits survive tab switches
    @Published var contentState: LoadState<[ContentEntry]> = .never
    var contentEntries: [ContentEntry] { contentState.value ?? [] }
    var contentError: String? { contentState.error }
    var contentLoading: Bool { contentState.isLoading }
    @Published var editor: EditorDocument?          // nil = browsing
    @Published var editorDirty = false

    // Free scan-only waiting list (Supabase review_queue)
    @Published var reviewQueueState: LoadState<[ReviewQueueItem]> = .never
    var reviewQueue: [ReviewQueueItem] { reviewQueueState.value ?? [] }
    var reviewQueueError: String? { reviewQueueState.error }
    var reviewQueueLoading: Bool { reviewQueueState.isLoading }

    /* What the last ingest run believed it had queued. Held beside the
       queue itself so the two can be compared — see contradiction(). */
    @Published var lastRunQueued: Int?
    @Published var lastRun: SupabaseAPI.LastRun?
    private var pollTask: Task<Void, Never>?

    /// How often the waiting list reloads while the workspace is open.
    ///
    /// The ingest schedule is every two hours, so polling faster buys
    /// nothing; polling slower means the app can sit for a whole working day
    /// showing a number that stopped being true before lunch. Five minutes is
    /// cheap — one PostgREST select — and it is what turns "I don't have the
    /// feeling it updates" into a screen that visibly moves.
    static let pollSeconds: UInt64 = 300

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: WorkspaceModel.pollSeconds * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.loadReviewQueue()
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// When the pipeline last ran, in the words a person would use.
    var pipelineLine: String? {
        guard let r = lastRun else { return nil }
        let stamp = r.finished_at ?? r.started_at
        guard let iso = stamp, let when = TrackerFreshness.parseISO(iso) else {
            return "Pipeline: no run recorded yet."
        }
        let ago = LoadState<Int>.ago(when)
        let n = r.items_queued ?? 0
        let src = r.sources_scanned.map { " · \($0) sources" } ?? ""
        let state = (r.status ?? "").isEmpty ? "" : " · \(r.status!)"
        /* Ingest runs every two hours. Past three, something is wrong with the
           schedule and the number on this screen is older than it looks. */
        let stale = Date().timeIntervalSince(when) > 3 * 3600
        return (stale ? "⚠ Pipeline last ran \(ago)" : "Pipeline ran \(ago)")
            + " · \(n) queued\(src)\(state)"
    }

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
            deploysState = .failed("No netlify_site_id configured for this project (projects.json).", at: Date())
            return
        }
        deploysState.beginLoading()
        do {
            deploysState = .loaded(try await NetlifyAPI.deploys(siteId: siteId), at: Date())
        } catch {
            deploysState = .failed(error.localizedDescription, at: Date())
        }
    }

    func triggerDeploy() async {
        triggering = true
        do {
            try await NetlifyAPI.triggerBuildHook()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadDeploys()
        } catch {
            deploysState = .failed(error.localizedDescription, at: Date())
        }
        triggering = false
    }

    // MARK: Repo

    func loadRepo() async {
        guard let repo = site.repo, !repo.isEmpty else {
            repoState = .failed("No repo configured for this project (projects.json).", at: Date())
            return
        }
        repoState.beginLoading()
        do {
            async let c = GitHubAPI.commits(repo: repo)
            async let p = GitHubAPI.pulls(repo: repo)
            async let d = GitHubAPI.listDir(repo: repo, path: "data")
            let (cs, ps, ds) = try await (c, p, d)
            repoState = .loaded(cs, at: Date())
            pulls = ps
            dataFiles = ds.filter { $0.type == "file" && $0.name.hasSuffix(".json") }
        } catch {
            repoState = .failed(error.localizedDescription, at: Date())
        }
    }

    // MARK: Tools

    /* ── How the tool register is derived ─────────────────────────────
       There is no tools.json on the site, and there should not be: a
       register somebody has to remember to update is a register that
       quietly stops being true. So this reads the two facts that are
       already in the repo and cannot drift from it.

       Pass one, the scripts. Every instrument is booted by a script in
       assets/js that queries its container by attribute. A MOUNT POINT is
       queried without a root:  $$('[data-fundflow]')
       An inner part is queried with one:  $('[data-ff-svg]', root)
       That single comma is the whole distinction, and it holds: run
       against the live repo it separates 30 mount points from 169 inner
       parts with no overlap at all.

       Pass two, the pages. A page that carries the attribute mounts the
       instrument; a page that also loads the script drives it. Where the
       two disagree the reader clicks something dead, which is exactly the
       kind of rot nobody notices, so it is reported rather than hidden. */

    func loadTools(force: Bool = false) async {
        if !force, case .loaded = toolsState { return }
        guard let repo = site.repo, !repo.isEmpty else {
            toolsState = .failed(
                "This project has no repo configured, so there is nothing to read the instruments out of.",
                at: Date())
            return
        }
        toolsState.beginLoading()
        do {
            let tree = try await GitHubAPI.tree(repo: repo)
            let scriptPaths = tree.filter {
                $0.type == "blob" && $0.path.hasPrefix("assets/js/") && $0.path.hasSuffix(".js")
            }.map(\.path)
            /* The German mirror under de/ repeats every page, and preview/
               holds unpublished drafts. Counting either would double or
               inflate the register without adding an instrument. */
            let pagePaths = tree.filter {
                $0.type == "blob" && $0.path.hasSuffix(".html")
                    && !$0.path.hasPrefix("de/")
                    && !$0.path.hasPrefix("preview/")
                    && !$0.path.hasPrefix("scripts/")
            }.map(\.path)

            let scripts = try await Self.fetchAll(repo: repo, paths: scriptPaths)
            var mountToScript: [String: String] = [:]
            for (path, text) in scripts {
                for attr in Self.mountPoints(in: text) { mountToScript[attr] = path }
            }
            guard !mountToScript.isEmpty else {
                toolsState = .failed(
                    "Read \(scripts.count) scripts and found no mount point in any of them. "
                        + "Either this project mounts its instruments some other way, or the read failed.",
                    at: Date())
                return
            }

            let pages = try await Self.fetchAll(repo: repo, paths: pagePaths)
            var mountedOn: [String: [String]] = [:]
            var unwiredOn: [String: [String]] = [:]
            for (path, html) in pages {
                let loaded = Self.scriptSources(in: html)
                for (attr, js) in mountToScript where Self.mounts(attr, in: html) {
                    mountedOn[attr, default: []].append(path)
                    if !loaded.contains(js) { unwiredOn[attr, default: []].append(path) }
                }
            }

            let list: [SiteTool] = mountToScript.keys.map { attr in
                let pages = (mountedOn[attr] ?? []).sorted()
                let unwired = (unwiredOn[attr] ?? []).sorted()
                return SiteTool(attribute: attr,
                                name: SiteTool.readableName(for: attr),
                                script: mountToScript[attr],
                                pages: pages,
                                unwiredPages: unwired)
            }
            /* Findings first: an instrument that is dead or orphaned is
               the reason to open this list at all, so it does not sit at
               the bottom where a long register buries it. */
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.pages.count != b.pages.count { return a.pages.count > b.pages.count }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            toolsScanned = ToolScanScope(scripts: scripts.count, pages: pages.count)
            toolsState = .loaded(list, at: Date())
        } catch {
            toolsState = .failed(error.localizedDescription, at: Date())
        }
    }

    /* ── Reading many files without hammering the API ─────────────────
       A site of this size is roughly 150 files per scan. Sequentially
       that is a visibly slow panel; unbounded it is a burst GitHub is
       entitled to throttle. Eight at a time is the compromise, and the
       result is cached until the user asks for a fresh read.

       A file that fails is skipped rather than failing the whole scan:
       one unreadable page should cost that page, not the register. */
    private static func fetchAll(repo: String, paths: [String]) async throws -> [(String, String)] {
        var out: [(String, String)] = []
        var remaining = paths[...]
        try await withThrowingTaskGroup(of: (String, String)?.self) { group in
            func addNext() {
                guard let path = remaining.popFirst() else { return }
                group.addTask {
                    guard let text = try? await GitHubAPI.file(repo: repo, path: path).decodedText()
                    else { return nil }
                    return (path, text)
                }
            }
            for _ in 0..<min(8, paths.count) { addNext() }
            while let finished = try await group.next() {
                if let finished { out.append(finished) }
                addNext()
            }
        }
        return out
    }

    // MARK: Sanctions dossiers

    /// One request: the repo tree already lists every file, so the stock
    /// of dossiers is a filter over it rather than a second scan.
    func loadDossiers(force: Bool = false) async {
        if !force, case .loaded = dossiersState { return }
        guard let repo = site.repo, !repo.isEmpty else {
            dossiersState = .failed(
                "This project has no repo configured, so the dossiers cannot be counted.",
                at: Date())
            return
        }
        dossiersState.beginLoading()
        do {
            let tree = try await GitHubAPI.tree(repo: repo)
            let rows = tree.filter {
                $0.type == "blob"
                    && $0.path.hasPrefix("politics/sanctions/")
                    && $0.path.hasSuffix(".html")
                    && !$0.path.hasSuffix("/index.html")
            }.map { item -> SiteDossier in
                let file = item.path.split(separator: "/").last.map(String.init) ?? item.path
                return SiteDossier(path: item.path,
                                   slug: file.replacingOccurrences(of: ".html", with: ""))
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            dossiersState = .loaded(rows, at: Date())
        } catch {
            dossiersState = .failed(error.localizedDescription, at: Date())
        }
    }

    /// Mount points in one script: `[data-x]` queried WITHOUT a root.
    static func mountPoints(in js: String) -> Set<String> {
        let pattern = #"(?:\$\$?|document\.querySelectorAll|document\.querySelector)\(\s*['"]\[(data-[a-z0-9-]+)\]['"]\s*\)"#
        return Set(js.matches(pattern, group: 1))
    }

    /// The scripts a page loads, normalised so `/assets/js/x.js?v=abc`
    /// and `assets/js/x.js` compare equal. The cache-busting stamp is the
    /// reason a naive comparison would report every page as unwired.
    static func scriptSources(in html: String) -> Set<String> {
        let pattern = #"<script[^>]+src="([^"]+)""#
        return Set(html.matches(pattern, group: 1).map { src in
            String(src.split(separator: "?")[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        })
    }

    /// Whether a page mounts this attribute. The trailing boundary keeps
    /// `data-filter-root` from matching inside `data-filter-root-extra`.
    static func mounts(_ attr: String, in html: String) -> Bool {
        html.range(of: "\(attr)(?=[\\s=>\"'/]|$)", options: .regularExpression) != nil
    }

    /// Load the free ingest waiting list from Supabase `review_queue`.
    func loadReviewQueue() async {
        guard SupabaseAPI.isConfigured() else {
            /* Not configured is not the same as empty, and it is certainly
               not "trigger a scan". Stay at .never and let the panel say so. */
            reviewQueueState = .never
            return
        }
        reviewQueueState.beginLoading()
        do {
            async let run = try? SupabaseAPI.lastRun()
            let rows = try await SupabaseAPI.listReviewQueue()
            lastRun = await run
            reviewQueueState = .loaded(rows, at: Date())
        } catch {
            reviewQueueState = .failed(error.localizedDescription, at: Date())
        }
        /* Ask the pipeline what it thinks it queued. If the two disagree the
           queue is not empty, it is unreachable — which is exactly what
           happened when the RLS policies were missing. */
        lastRunQueued = try? await SupabaseAPI.lastRunItemsQueued()
    }

    /// The one thing this app can see that nothing else in the stack can:
    /// both sides of the same number.
    var queueContradiction: String? {
        guard case .loaded(let rows, _) = reviewQueueState,
              rows.isEmpty, let claimed = lastRunQueued, claimed > 0 else { return nil }
        return "The last ingest run reported \(claimed) item(s) queued, but the "
             + "waiting list returns none. That is a permissions or policy "
             + "problem, not an empty queue."
    }

    func refreshEditorial() async {
        async let content: Void = loadContentList()
        async let queue: Void = loadReviewQueue()
        _ = await (content, queue)
    }
}

// MARK: - Workspace view (top bar + tab chips + content)

struct WorkspaceView: View {
    let site: SiteProject
    @StateObject private var model: WorkspaceModel

    /// The section lives on the model now, so the sidebar and the view
    /// cannot disagree about which one is open.
    private var tab: WorkspaceTab { model.tab }

    /* The saved section is restored on the MODEL, once, the first time it
       is asked for. It used to be restored here, in the view's init, and
       that was survivable only as long as nothing else observed the
       model: an init runs during a view update, so writing a @Published
       property there invalidates every observer mid-update. The moment
       the sidebar started observing the same model to mark the current
       row, that write became a loop, and the window hung during
       restoration before it ever appeared. State belongs to the model,
       and a view's init is not a place to change state. */
    init(site: SiteProject) {
        self.site = site
        _model = StateObject(wrappedValue: WorkspaceModel.shared(for: site))
    }

    @EnvironmentObject var chrome: ChromeModel

    var body: some View {
        VStack(spacing: 0) {
            if !chrome.focus && !(tab == .content && model.editorFull) {
                topBar
                Divider()
            }
            content
        }
        .animation(.easeInOut(duration: 0.15), value: tab)
        .animation(.easeInOut(duration: 0.15), value: chrome.focus)
        .background(Color.brandCream)
        .navigationTitle(site.name)
    }

    /* The chips are gone. Fourteen sections would not fit in a row, and
       even six of them wrapped on a narrow window: the screenshot that
       started this rebuild showed "Overvie w" and "Calenda r" broken
       across two lines. The sidebar carries them now, where a list can
       be as long as it needs to be, and this bar states where you are. */
    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: tab.icon).font(.system(size: 12))
                .foregroundColor(.textSecondary)
            Text(tab.title).font(.system(size: 13, weight: .semibold))
            if tab == .content && model.editorDirty {
                Circle().fill(Color.brandGold).frame(width: 6, height: 6)
            }
            Spacer()
            if let urlStr = site.url, let url = URL(string: urlStr) {
                Link(urlStr.replacingOccurrences(of: "https://", with: ""), destination: url)
                    .font(.caption).foregroundColor(.textSecondary)
            }
            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
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
            Pill(text: "No Netlify id", color: .statusAmber)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewTabView(model: model, site: site, onOpen: { entry in
            model.tab = .content
            Task { await model.openEntry(entry) }
        })
        case .content:  ContentTabView(model: model, openDeploys: { model.tab = .deploys })
        case .tools:    ToolsTabView(model: model, site: site)
        case .planner:  CalendarTabView(model: model, openArticle: { entry in
                            model.tab = .content
                            Task { await model.openEntry(entry) }
                        })
        case .radar:       RadarView()
        case .analytics:   AnalyticsView()
        case .tracker:     TrackerView()
        case .defence:     DefenceEditorView()
        case .pipeline:    PipelineView()
        case .trilogue:    TrilogueView()
        case .enforcement: EnforcementView()
        case .sanctions:   SanctionsTabView(model: model, site: site)
        case .cms:      CMSTabView(site: site)
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

// MARK: - Overview tab (live editorial pipeline from the content list)

struct OverviewTabView: View {
    @ObservedObject var model: WorkspaceModel
    let site: SiteProject
    var onOpen: (ContentEntry) -> Void

    private var published: [ContentEntry] { model.contentEntries.filter { $0.status == "published" } }
    private var scheduled: [ContentEntry] { model.contentEntries.filter { !$0.scheduled.isEmpty } }
    private var drafts: [ContentEntry] {
        model.contentEntries.filter { $0.isDraft && !$0.isAIDraft && $0.scheduled.isEmpty }
    }
    private var aiDrafts: [ContentEntry] { model.contentEntries.filter { $0.isAIDraft && $0.scheduled.isEmpty } }
    @ObservedObject private var radar = RadarStore.shared
    @State private var selected: ContentEntry?
    @State private var showQueue = false

    /// Total words across all articles, compacted ("12.4k") past 10k.
    private var wordsWritten: String {
        let total = model.contentEntries.reduce(0) { $0 + $1.words }
        if total >= 10_000 { return String(format: "%.1fk", Double(total) / 1000) }
        return "\(total)"
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            if let sel = selected {
                Divider()
                ArticleDetailRail(entry: sel, site: site,
                                  openEditor: { onOpen(sel) },
                                  close: { withAnimation(.spring(duration: 0.25)) { selected = nil } })
                    .frame(width: 330)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: model.contentEntries) { _, new in
            if let s = selected { selected = new.first { $0.id == s.id } }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DeskView(model: model,
                             openQueue: { withAnimation { showQueue = true } },
                             openEntry: { e in onOpen(e) },
                             seedDraft: { key, items in
                                 /* No author: the app does not know whose byline
                                    this is, and guessing one is a claim. */
                                 model.newDraftFromQueue(clusterKey: key, items: items, author: "")
                             })

                waitingListSection

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("PUBLISHING RHYTHM · 12 WEEKS")
                                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                                .foregroundColor(.textSecondary)
                            Spacer()
                            HStack(spacing: 10) {
                                Label("Published", systemImage: "square.fill")
                                    .font(.system(size: 10)).foregroundColor(.stApplied)
                                Label("Scheduled", systemImage: "square.fill")
                                    .font(.system(size: 10)).foregroundColor(.statusAmber)
                            }
                            .labelStyle(.titleAndIcon)
                        }
                        RhythmGrid(entries: model.contentEntries)
                    }
                }

                HStack {
                    Text("Editorial pipeline")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    if model.contentLoading || model.reviewQueueLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await model.refreshEditorial() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }

                if let err = model.contentError {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Content list", systemImage: "exclamationmark.triangle")
                                .fontWeight(.semibold).foregroundColor(.statusRed)
                            Text(err).foregroundColor(.textSecondary).font(.callout)
                        }
                    }
                } else if model.contentEntries.isEmpty && !model.contentLoading {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No articles yet").fontWeight(.semibold)
                            Text("Create your first draft in the Content tab — everything you write shows up here, live from the repo.")
                                .foregroundColor(.textSecondary).font(.callout)
                        }
                    }
                } else {
                    LazyVGrid(columns: grid(min: 320), spacing: 14) {
                        ForEach(model.contentEntries) { entry in
                            Button {
                                withAnimation(.spring(duration: 0.25)) {
                                    selected = (selected?.id == entry.id) ? nil : entry
                                }
                            } label: {
                                Card {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            entryPill(entry)
                                            if !entry.type.isEmpty {
                                                Pill(text: entry.type.uppercased(), color: .textSecondary)
                                            }
                                            Spacer()
                                            Text(prettyDate(entry.scheduled.isEmpty ? entry.date : entry.scheduled))
                                                .font(.caption).foregroundColor(.textSecondary)
                                        }
                                        Text(entry.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.textPrimary)
                                            .multilineTextAlignment(.leading)
                                        if entry.isAIDraft {
                                            Text(entry.reviewRequired
                                                 ? "AI Draft · Review Required"
                                                 : "Generated by the ingest pipeline")
                                                .font(.caption)
                                                .foregroundColor(.statusAmber)
                                        }
                                        HStack(spacing: 8) {
                                            if !entry.topic.isEmpty {
                                                Text(entry.topic.capitalized)
                                                    .font(.caption).foregroundColor(.textSecondary)
                                            }
                                            Text("\(entry.words) words")
                                                .font(.caption).foregroundColor(.textSecondary)
                                            Spacer()
                                            if let live = entry.liveURL(site: site.url), let url = URL(string: live) {
                                                Link(destination: url) {
                                                    Label("Live", systemImage: "arrow.up.right")
                                                        .font(.caption)
                                                }
                                            }
                                            Label("Details", systemImage: "sidebar.right")
                                                .font(.caption).foregroundColor(.accentNavy)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentNavy.opacity(selected?.id == entry.id ? 0.55 : 0),
                                            lineWidth: 1.5)
                            )
                            .help("Show details — the panel has the editor button")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if model.contentEntries.isEmpty { await model.loadContentList() }
            await model.loadReviewQueue()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var waitingListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("News waiting list")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.textPrimary)
                Spacer()
                if model.reviewQueueLoading { ProgressView().controlSize(.small) }
                /* Provenance, not decoration. A count without a time is a
                   claim without a date, which is the thing this project
                   exists to avoid. */
                Text(model.reviewQueueState.provenance(source: "review_queue"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }

            /* Whether the schedule is alive, said out loud. Reading a queue
               tells you what is in it, never whether anything is still being
               put there — and a list that stopped being fed looks exactly
               like a quiet week. Refreshes itself every five minutes. */
            if let line = model.pipelineLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(line.hasPrefix("⚠") ? .statusAmber : .textSecondary)
            }

            if !SupabaseAPI.isConfigured() {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect Supabase to see scanned news").fontWeight(.semibold)
                        Text("Settings → Accounts → paste your project URL and anon (publishable) key. Then run the ingest Edge Function — interesting items appear here for review.")
                            .foregroundColor(.textSecondary).font(.callout)
                    }
                }
            } else if let err = model.reviewQueueError {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Waiting list", systemImage: "exclamationmark.triangle")
                            .fontWeight(.semibold).foregroundColor(.statusRed)
                        Text(err).foregroundColor(.textSecondary).font(.callout)
                        Text("If this is a permissions error, run the SQL grant in supabase/SCAN_ONLY_SETUP.md (anon select on review_queue).")
                            .foregroundColor(.textSecondary).font(.caption)
                    }
                }
            } else if let clash = model.queueContradiction {
                /* The alarm nothing else in the stack can raise: the run says
                   it queued items, the queue returns none. Saying "empty" here
                   was the wrong advice on 9 August and cost an hour. */
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The queue and the pipeline disagree", systemImage: "exclamationmark.2")
                            .fontWeight(.semibold).foregroundColor(.statusAmber)
                        Text(clash).foregroundColor(.textSecondary).font(.callout)
                        Text("Check the anon SELECT policy on ingested_items and the column grants — supabase/SCAN_ONLY_SETUP.md.")
                            .foregroundColor(.textSecondary).font(.caption)
                    }
                }
            } else if case .never = model.reviewQueueState {
                /* Not asked yet is not empty. The old code could not tell the
                   difference and asserted "empty" before the first fetch. */
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not loaded yet").fontWeight(.semibold)
                        Text("The waiting list has not been fetched in this session.")
                            .foregroundColor(.textSecondary).font(.callout)
                        Button("Load now") { Task { await model.loadReviewQueue() } }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }
            } else if model.reviewQueueState.isConfirmedEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Waiting list is empty").fontWeight(.semibold)
                        Text("Checked \(LoadState<Int>.ago(model.reviewQueueState.stamp ?? Date())) — nothing scored above the threshold. Trigger the ingest scan for a fresh sweep; nothing is written automatically.")
                            .foregroundColor(.textSecondary).font(.callout)
                    }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.reviewQueue.prefix(25)) { item in
                        ReviewQueueRow(item: item, seedDraft: { it in
                            model.newDraftFromQueue(clusterKey: DraftSeed.keyFor(it),
                                                    items: [it], author: "")
                        })
                    }
                    if model.reviewQueue.count > 25 {
                        Text("Showing 25 of \(model.reviewQueue.count) — open Supabase Table Editor for the rest.")
                            .font(.caption).foregroundColor(.textSecondary)
                    }
                }
            }
        }
    }

    private func entryPill(_ e: ContentEntry) -> some View {
        let (text, color): (String, Color) = {
            if !e.scheduled.isEmpty { return ("SCHEDULED", .statusAmber) }
            if e.isAIDraft { return ("AI DRAFT", .statusAmber) }
            if e.status == "concept" { return ("CONCEPT", .statusAmber) }
            if e.isDraft { return ("DRAFT", .brandNavy) }
            if e.status == "published" { return ("PUBLISHED", .statusGreen) }
            return (e.status.uppercased(), .textSecondary)
        }()
        return Pill(text: text, color: color)
    }
}

/// One scanned news candidate on the free waiting list.
struct ReviewQueueRow: View {
    let item: ReviewQueueItem
    /// Present only where a draft can actually be opened.
    var seedDraft: ((ReviewQueueItem) -> Void)? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Pill(text: "QUEUE", color: .statusAmber)
                    if let src = item.source_name, !src.isEmpty {
                        Text(src).font(.caption).foregroundColor(.textSecondary)
                    }
                    Spacer()
                    Text(item.scoreLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.statusAmber)
                        .help(item.relevance_reason ?? "Keyword score")
                    if let d = item.ageDays, d >= ReviewQueueItem.retainQueuedDays - 7 {
                        Text("\(ReviewQueueItem.retainQueuedDays - d) d left")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.statusRed)
                            .help("Queued items are deleted after \(ReviewQueueItem.retainQueuedDays) days.")
                    }
                }
                Text(item.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.leading)
                if !item.displaySnippet.isEmpty {
                    Text(item.displaySnippet)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }
                HStack {
                    if let reason = item.relevance_reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 10.5))
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let seed = seedDraft {
                        Button { seed(item) } label: {
                            Label("Draft from this", systemImage: "square.and.pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentNavy)
                        .help("Opens a brief seeded with this item's title, link and "
                              + "retrieval date — one outlet, so it will say so.")
                    }
                    if let url = item.openURL {
                        Link(destination: url) {
                            Label("Open source", systemImage: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Publishing rhythm (GitHub-style dot matrix)

/// Twelve Monday-first weeks — nine back, three ahead — one dot per
/// day: green = published articles, amber = scheduled ones, so the
/// plan ahead is visible next to the track record. Every dot comes
/// from real entry dates; empty stays empty.
struct RhythmGrid: View {
    let entries: [ContentEntry]

    private static let day: TimeInterval = 86_400
    private var cal: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        return c
    }

    private struct DayMark { var published = 0; var scheduled = 0 }

    private var marks: [Date: DayMark] {
        var out: [Date: DayMark] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        for e in entries {
            if e.status == "published", let d = f.date(from: String(e.date.prefix(10))) {
                out[cal.startOfDay(for: d), default: DayMark()].published += 1
            }
            if !e.scheduled.isEmpty, let d = f.date(from: String(e.scheduled.prefix(10))) {
                out[cal.startOfDay(for: d), default: DayMark()].scheduled += 1
            }
        }
        return out
    }

    private var weekStarts: [Date] {
        let today = cal.startOfDay(for: Date())
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        guard let thisWeek = cal.date(from: comps) else { return [] }
        return (-8...3).compactMap { cal.date(byAdding: .weekOfYear, value: $0, to: thisWeek) }
    }

    var body: some View {
        let m = marks
        let today = cal.startOfDay(for: Date())
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(["Mon", "", "Wed", "", "Fri", "", ""], id: \.self) { l in
                    Text(l).font(.system(size: 8.5)).foregroundColor(.textSecondary)
                        .frame(height: 10)
                }
            }
            ForEach(weekStarts, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { dow in
                        let date = week.addingTimeInterval(Double(dow) * Self.day)
                        cell(for: date, mark: m[date], isToday: date == today)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for date: Date, mark: DayMark?, isToday: Bool) -> some View {
        let color: Color = {
            guard let mk = mark else { return .cardBorder.opacity(0.45) }
            if mk.published > 0 { return .stApplied.opacity(mk.published > 1 ? 1 : 0.75) }
            if mk.scheduled > 0 { return .statusAmber }
            return .cardBorder.opacity(0.45)
        }()
        RoundedRectangle(cornerRadius: 2.5)
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(Color.accentNavy, lineWidth: isToday ? 1.2 : 0)
            )
            .help(tooltip(for: date, mark: mark))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private func tooltip(for date: Date, mark: DayMark?) -> String {
        let day = Self.dayFormatter.string(from: date)
        let n = (mark?.published ?? 0) + (mark?.scheduled ?? 0)
        return n > 0 ? "\(n) article\(n == 1 ? "" : "s") · \(day)" : day
    }
}

// MARK: - Article detail rail (Branch-style context panel)

/// Right-hand context panel: click an article in Overview and its
/// details slide in WITHOUT leaving the list — status, dates, an
/// honest readiness checklist, and the real actions. The pattern from
/// the Branch "PR details" shot (Collect UI research).
struct ArticleDetailRail: View {
    let entry: ContentEntry
    let site: SiteProject
    var openEditor: () -> Void
    var close: () -> Void

    private var statusColor: Color {
        if entry.status == "published" { return .stApplied }
        if !entry.scheduled.isEmpty { return .statusAmber }
        if entry.isAIDraft { return .statusAmber }
        return .textSecondary
    }
    private var statusLine: String {
        if entry.status == "published" { return "Published" }
        if !entry.scheduled.isEmpty { return "Scheduled · \(prettyDate(entry.scheduled))" }
        if entry.isAIDraft {
            return entry.reviewRequired ? "AI Draft · Review Required" : "AI Draft"
        }
        if entry.status == "concept" { return "Concept" }
        return "Draft"
    }

    private var checks: [(Bool, String)] {
        [(!entry.title.isEmpty, "Title set"),
         (entry.words >= 300, "At least 300 words (\(entry.words))"),
         (!entry.topic.isEmpty, "Topic assigned"),
         (!entry.type.isEmpty, "Article type chosen")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close details (Esc)")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.title.isEmpty ? entry.name : entry.title)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !entry.preview.isEmpty {
                        Text(entry.preview)
                            .font(.system(size: 12.5))
                            .foregroundColor(.textSecondary)
                            .lineLimit(3)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        metaRow("Date", entry.date.isEmpty ? "–" : prettyDate(entry.date))
                        if !entry.scheduled.isEmpty { metaRow("Goes live", prettyDate(entry.scheduled)) }
                        metaRow("Words", "\(entry.words)")
                        if !entry.topic.isEmpty { metaRow("Topic", entry.topic.capitalized) }
                        if !entry.type.isEmpty { metaRow("Type", entry.type.capitalized) }
                        if entry.isAIDraft { metaRow("Origin", "AI ingest pipeline") }
                        metaRow("File", entry.name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("READY TO PUBLISH?")
                            .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                            .foregroundColor(.textSecondary)
                        ForEach(checks, id: \.1) { ok, label in
                            HStack(spacing: 6) {
                                Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(ok ? .stApplied : .textSecondary)
                                Text(label).font(.system(size: 12.5))
                                    .foregroundColor(.textPrimary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button(action: openEditor) {
                    Label("Open in editor", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.accentNavySolid)
                .controlSize(.large)

                HStack(spacing: 12) {
                    if let live = entry.liveURL(site: site.url), let url = URL(string: live) {
                        Link(destination: url) {
                            Label("Live", systemImage: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    if let repo = site.repo,
                       let url = URL(string: "https://github.com/\(repo)/blob/\(site.default_branch ?? "main")/\(entry.path)") {
                        Link(destination: url) {
                            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCard)
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12)).foregroundColor(.textSecondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(.textPrimary)
            Spacer(minLength: 0)
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
    @State private var showDiagnostics = false
    @State private var plausibleKey = ""
    @State private var mailerliteKey = ""
    @State private var supabaseURL = ""
    @State private var supabaseAnonKey = ""
    @ObservedObject private var canva = CanvaAuth.shared

    /// Preferences sections — icon rail on the left, one pane at a
    /// time on the right (macOS System Settings pattern). Onboarding
    /// keeps the old single-scroll flow: a newcomer should see every
    /// field at once, not hunt through tabs.
    enum Pane: String, CaseIterable, Identifiable {
        case accounts, canva, analytics, ingest, feeds, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .accounts:  return "Accounts"
            case .canva:     return "Canva"
            case .analytics: return "Analytics"
            case .ingest:    return "Ingest"
            case .feeds:     return "Feeds"
            case .about:     return "About"
            }
        }
        var icon: String {
            switch self {
            case .accounts:  return "key.fill"
            case .canva:     return "paintbrush.fill"
            case .analytics: return "chart.bar.fill"
            case .ingest:    return "tray.and.arrow.down.fill"
            case .feeds:     return "antenna.radiowaves.left.and.right"
            case .about:     return "info.circle.fill"
            }
        }
    }
    @State private var pane: Pane = .accounts

    var body: some View {
        VStack(spacing: 0) {
            if onboarding {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Welcome to LexCockpit")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.textPrimary)
                        Text("One-time setup: paste the keys you have, press Save, then hit each Test button — green means the pipeline works. You can skip anything and add it later via the gear icon.")
                            .font(.callout).foregroundColor(.textSecondary)
                        keychainNote
                        accountsPane
                        Divider()
                        canvaPane
                        Divider()
                        analyticsPane
                        Divider()
                        ingestPane
                        Divider()
                        feedsPane
                    }
                    .padding(22)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Pane.allCases) { p in
                            Button { pane = p } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: p.icon)
                                        .font(.system(size: 12))
                                        .foregroundColor(pane == p ? .accentNavy : .textSecondary)
                                        .frame(width: 18)
                                    Text(p.title)
                                        .font(.system(size: 13, weight: pane == p ? .semibold : .regular))
                                        .foregroundColor(.textPrimary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(pane == p ? Color.navyTint : .clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(width: 172)
                    .background(Color.bgCard)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(pane.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.textPrimary)
                            switch pane {
                            case .accounts:  keychainNote; accountsPane
                            case .canva:     canvaPane
                            case .analytics: analyticsPane
                            case .ingest:    ingestPane
                            case .feeds:     feedsPane
                            case .about:     aboutPane
                            }
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Divider()
            HStack {
                Button("Diagnostics…") { showDiagnostics = true }
                    .controlSize(.small)
                if saved { Label("Saved to Keychain", systemImage: "checkmark.circle.fill").foregroundColor(.stApplied) }
                Spacer()
                Button(onboarding ? "Los geht's" : "Close") {
                    if onboarding { UserDefaults.standard.set(true, forKey: "onboardedV1") }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { saveAll() }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color.bgCard)
        }
        .frame(width: onboarding ? 560 : 720, height: 640)
        .sheet(isPresented: $showDiagnostics) { DiagnosticsSheet() }
    }

    private func saveAll() {
        if !netlifyPAT.isEmpty { Keychain.set(Keychain.netlifyPAT, netlifyPAT) }
        if !buildHook.isEmpty { Keychain.set(Keychain.netlifyBuildHook, buildHook) }
        if !githubPAT.isEmpty { Keychain.set(Keychain.githubPAT, githubPAT) }
        if !plausibleKey.isEmpty { Keychain.set(Keychain.plausibleKey, plausibleKey) }
        if !mailerliteKey.isEmpty { Keychain.set(Keychain.mailerliteKey, mailerliteKey) }
        if !supabaseURL.isEmpty { Keychain.set(Keychain.supabaseURL, supabaseURL) }
        if !supabaseAnonKey.isEmpty { Keychain.set(Keychain.supabaseAnonKey, supabaseAnonKey) }
        plausibleKey = ""; mailerliteKey = ""
        supabaseURL = ""; supabaseAnonKey = ""
        netlifyPAT = ""; buildHook = ""; githubPAT = ""
        UserDefaults.standard.set(
            feedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: "feedBaseURL")
        UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
        saved = true
    }

    private var keychainNote: some View {
        Text("Tokens are stored only in the macOS Keychain — never in files, code or logs.")
            .font(.callout).foregroundColor(.textSecondary)
    }

    @ViewBuilder private var accountsPane: some View {
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
    }

    @ViewBuilder private var canvaPane: some View {
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
    }

    @ViewBuilder private var analyticsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    }

    @ViewBuilder private var ingestPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free news waiting list (Supabase)")
                .font(.callout.weight(.semibold))
            Text("Read-only. Paste the project URL + anon/publishable key — never the service_role key. The Overview tab shows scanned RSS hits from review_queue.")
                .font(.caption).foregroundColor(.textSecondary)
            field("Supabase project URL", text: $supabaseURL,
                  hint: Keychain.defaultSupabaseURL,
                  present: Keychain.has(Keychain.supabaseURL))
            field("Supabase anon (publishable) key", text: $supabaseAnonKey,
                  hint: "Dashboard → Project Settings → API → anon public",
                  present: Keychain.has(Keychain.supabaseAnonKey))
            testRow("supabase", "Test waiting list") { await ConnectionTest.supabase() }
        }
    }

    @ViewBuilder private var feedsPane: some View {
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
    }

    @ViewBuilder private var aboutPane: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("LexCockpit").font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundColor(.textPrimary)
                Text("Version \(AppVersion.display)")
                    .font(.callout).foregroundColor(.textSecondary)
            }
            Spacer()
        }
        Text("Editorial cockpit for LexDigestGlobal — write, plan, publish, and watch the regulatory feeds. Tokens live in the macOS Keychain; article bytes are protected by the block vault.")
            .font(.callout).foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        UpdatePanel()

        if let url = URL(string: "https://github.com/tg-netizen/lexcockpit/releases") {
            Link("All releases on GitHub", destination: url).font(.callout)
        }
        Button("Show what's new") {
            UserDefaults.standard.removeObject(forKey: "lastSeenVersion")
        }
        .controlSize(.small)
        .help("The what's-new window appears again on the next launch")
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
