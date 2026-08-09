import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tabs

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, content, planner, cms, deploys, repo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .content:  return "Content"
        case .planner:  return "Calendar"
        case .cms:      return "CMS"
        case .deploys:  return "Deploys"
        case .repo:     return "Repo"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .content:  return "doc.text"
        case .planner:  return "calendar"
        case .cms:      return "globe"
        case .deploys:  return "arrow.up.circle"
        case .repo:     return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Per-site model (cached, survives navigation)

@MainActor
final class WorkspaceModel: ObservableObject {
    let site: SiteProject

    /// Canva-style editor takeover: when true the Content tab shows ONLY the
    /// document editor (no library column, no workspace tab bar).
    @Published var editorFull = false

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
            let rows = try await SupabaseAPI.listReviewQueue()
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

    // Slim bar: the window title already carries the project name (V6) —
    // here only the tabs and the live status live.
    private var topBar: some View {
        HStack(spacing: 6) {
            ForEach(WorkspaceTab.allCases) { t in
                tabChip(t)
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
        case .overview: OverviewTabView(model: model, site: site, onOpen: { entry in
            tab = .content
            SessionHub.shared.state.workspaceTab = WorkspaceTab.content.rawValue
            Task { await model.openEntry(entry) }
        })
        case .content:  ContentTabView(model: model, openDeploys: { tab = .deploys })
        case .planner:  CalendarTabView(model: model, openArticle: { entry in
                            tab = .content
                            Task { await model.openEntry(entry) }
                        })
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
                             openEntry: { e in onOpen(e) })

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
                                                Pill(text: entry.type.uppercased(), color: .brandGold.opacity(0.9))
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
        }
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
                        ReviewQueueRow(item: item)
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
                }
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.leading)
                if let snip = item.snippet, !snip.isEmpty {
                    Text(snip)
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
                .buttonStyle(.borderedProminent).tint(.accentNavy)
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
