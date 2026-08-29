import SwiftUI
import AppKit

// MARK: - User-added projects (persisted, merged with the bundled config)

enum UserProjects {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/user-projects.json")
    }
    static func load() -> [SiteProject] {
        (try? JSONDecoder().decode([SiteProject].self, from: Data(contentsOf: file))) ?? []
    }
    static func save(_ sites: [SiteProject]) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sites) { try? data.write(to: file) }
    }
}

// MARK: - Home: greeting, project cards with direct actions, Today rail

struct ProjectHubView: View {
    @EnvironmentObject var store: CockpitStore
    var navigate: (SidebarSelection) -> Void
    /* The desks live inside a project now, so a tile on Home cannot just
       say "Radar", it has to say whose radar. With one site configured
       that is the site; with none the tile has nowhere to go and hides
       itself rather than pretending. */
    var openSection: (SiteProject, WorkspaceTab) -> Void
    private var primarySite: SiteProject? { store.sites.first }
    @State private var showAdd = false

    /// First name from the macOS account (real data, zero setup);
    /// falls back to the plain greeting when the account has no name.
    private var firstName: String? {
        let first = NSFullUserName().split(separator: " ").first.map(String.init)
        return (first?.isEmpty == false) ? first : nil
    }

    private var greeting: String {
        let base: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  base = "Good morning"
        case 12..<18: base = "Good afternoon"
        default:      base = "Good evening"
        }
        return firstName.map { "\(base), \($0)" } ?? base
    }

    private var todayLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date())
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                // ── Left: greeting + projects ──
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Text(greeting)
                                .font(.system(size: 30, weight: .bold, design: .serif))
                                .foregroundColor(.textPrimary)
                            BetaBadge()
                        }
                        Text(todayLine)
                            .font(.system(size: 14))
                            .foregroundColor(.textSecondary)
                    }

                    sectionLabel("Your projects")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)],
                              spacing: 16) {
                        ForEach(store.sites) { site in
                            ProjectCard(site: site,
                                        isUserAdded: store.isUserSite(site.id),
                                        openTab: { tab in openProject(site, tab: tab) },
                                        remove: { store.removeUserSite(site.id) })
                        }
                        AddProjectTile { showAdd = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // ── Right: Today rail ──
                TodayRail(navigate: navigate, openSection: openSection)
                    .frame(width: 292)
            }
            .padding(28)
        }
        /* The warm glow that used to sit here was a gradient from
           #F5F0E6 to #FAFAFA: a contrast of 1.088, which is below the
           threshold at which a screen shows a difference at all. It cost
           a gradient and a token and delivered nothing. The page is now
           the site's own warm paper, flat. */
        .background(Color.bgPage)
        .sheet(isPresented: $showAdd) { AddProjectSheet() }
    }

    private func openProject(_ site: SiteProject, tab: WorkspaceTab?) {
        if let tab = tab {
            SessionHub.shared.state.workspaceTab = tab.rawValue
        }
        SessionHub.shared.state.selectionSite = site.id
        SessionHub.shared.state.selectionSection = nil
        navigate(.site(site.id))
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(0.7)
            .foregroundColor(.textSecondary)
    }
}

// MARK: - Project card (status + direct paths into the work)

struct ProjectCard: View {
    let site: SiteProject
    let isUserAdded: Bool
    var openTab: (WorkspaceTab?) -> Void
    var remove: () -> Void

    @State private var hovering = false
    @StateObject private var model: WorkspaceModel

    init(site: SiteProject, isUserAdded: Bool,
         openTab: @escaping (WorkspaceTab?) -> Void, remove: @escaping () -> Void) {
        self.site = site
        self.isUserAdded = isUserAdded
        self.openTab = openTab
        self.remove = remove
        _model = StateObject(wrappedValue: WorkspaceModel.shared(for: site))
    }

    private var initials: String {
        String(site.name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
    }

    private var continuePath: String? {
        let s = SessionHub.shared.state
        guard s.selectionSite == site.id, let path = s.articlePath else { return nil }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — click = open the project
            Button { openTab(nil) } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.accentNavy)
                        Text(initials).font(.system(size: 16, weight: .bold)).foregroundColor(.bgCard)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.textPrimary).lineLimit(1)
                        if let url = site.url {
                            Text(url.replacingOccurrences(of: "https://", with: ""))
                                .font(.system(size: 12)).foregroundColor(.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    statusChip
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(18)

            // Stats line
            HStack(spacing: 6) {
                if !model.contentEntries.isEmpty {
                    let drafts = model.contentEntries.filter(\.isDraft).count
                    Text("\(model.contentEntries.count - drafts) live · \(drafts) in draft")
                } else if let repo = site.repo {
                    Text(repo)
                } else {
                    Text("Not fully configured — add repo & Netlify in the workspace")
                }
                Spacer()
            }
            .font(.system(size: 11.5)).foregroundColor(.textSecondary)
            .padding(.horizontal, 18).padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            // Direct paths — one click into the actual work
            HStack(spacing: 0) {
                if let path = continuePath {
                    actionButton("Continue", icon: "arrow.uturn.right") {
                        openTab(.content)
                        Task { await model.openPath(path) }
                    }
                } else {
                    actionButton("Write", icon: "square.and.pencil") { openTab(.content) }
                }
                actionButton("Calendar", icon: "calendar") { openTab(.planner) }
                actionButton("Deploys", icon: "arrow.up.circle") { openTab(.deploys) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.bgCard)
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.04),
                        radius: hovering ? 11 : 3, x: 0, y: hovering ? 4 : 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(hovering ? Color.accentNavy.opacity(0.4) : Color.cardBorder, lineWidth: 1))
        .scaleEffect(hovering ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            if let urlStr = site.url, let url = URL(string: urlStr) {
                Button("Open site in browser") { NSWorkspace.shared.open(url) }
            }
            if isUserAdded {
                Divider()
                Button("Remove project", role: .destructive, action: remove)
            }
        }
        .task {
            if model.deploys.isEmpty, Keychain.has(Keychain.netlifyPAT),
               !(site.netlify_site_id ?? "").isEmpty {
                await model.loadDeploys()
            }
            if model.contentEntries.isEmpty, Keychain.has(Keychain.githubPAT),
               site.repo != nil {
                await model.loadContentList()
            }
        }
    }

    @ViewBuilder private var statusChip: some View {
        if let deploy = model.deploys.first {
            HStack(spacing: 5) {
                Circle().fill(deployColor(deploy.stateKind)).frame(width: 7, height: 7)
                Text(deploy.state.capitalized).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(deployColor(deploy.stateKind).opacity(0.12)))
            .foregroundColor(deployColor(deploy.stateKind))
            .help("Last deploy \(relativeTime(deploy.created_at))")
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentNavy)
    }
}

// MARK: - Add tile

struct AddProjectTile: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                Text("Add project").font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(hovering ? .accentNavy : .textSecondary)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.bgCard.opacity(hovering ? 1 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(hovering ? Color.accentNavy.opacity(0.5) : Color.cardBorder,
                              style: StrokeStyle(lineWidth: 1.2, dash: [5])))
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add another website project (repo, CMS, Netlify)")
    }
}

// MARK: - Today rail (what needs attention, at a glance)

struct TodayRail: View {
    @EnvironmentObject var store: CockpitStore
    @ObservedObject private var radar = RadarStore.shared
    @ObservedObject private var queue = CommitQueue.shared
    @State private var waitingCount: Int? = nil
    var navigate: (SidebarSelection) -> Void
    /* The desks live inside a project now, so a tile on Home cannot just
       say "Radar", it has to say whose radar. With one site configured
       that is the site; with none the tile has nowhere to go and hides
       itself rather than pretending. */
    var openSection: (SiteProject, WorkspaceTab) -> Void

    private var nextDeadline: Regulation? {
        store.regulations
            .filter { $0.status == .upcoming && ($0.applicationDate ?? "") >= todayISO() }
            .sorted { ($0.applicationDate ?? "") < ($1.applicationDate ?? "") }
            .first
    }

    private func daysUntil(_ iso: String?) -> Int? {
        guard let iso = iso, let date = parseISO(iso) else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day
    }

    private var primarySite: SiteProject? { store.sites.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY")
                .font(.system(size: 11, weight: .semibold)).tracking(0.7)
                .foregroundColor(.textSecondary)

            // Next deadline
            railCard {
                if let reg = nextDeadline {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Next deadline").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            if let days = daysUntil(reg.applicationDate) {
                                Text("in \(days) days")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.statusAmber)
                            }
                        }
                        Text(reg.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text(prettyDate(reg.applicationDate))
                            .font(.system(size: 11)).foregroundColor(.textSecondary)
                    }
                } else {
                    Text("No upcoming deadlines.")
                        .font(.system(size: 12)).foregroundColor(.textSecondary)
                }
            }

            // News waiting list (free scan-only)
            if SupabaseAPI.isConfigured(), let n = waitingCount {
                Button {
                    if let site = primarySite {
                        SessionHub.shared.state.workspaceTab = WorkspaceTab.overview.rawValue
                        SessionHub.shared.state.selectionSite = site.id
                        SessionHub.shared.state.selectionSection = nil
                        navigate(.site(site.id))
                    }
                } label: {
                    railCard {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.full")
                                .foregroundColor(n > 0 ? .statusAmber : .statusGreen)
                            Text(n > 0
                                 ? "\(n) news item\(n == 1 ? "" : "s") waiting for review"
                                 : "News waiting list empty")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10)).foregroundColor(.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Radar
            Button { if let s = primarySite { openSection(s, .radar) } } label: {
                railCard {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundColor(radar.unseenCount > 0 ? .statusAmber : .statusGreen)
                        Text(radar.unseenCount > 0
                             ? "\(radar.unseenCount) regulation change\(radar.unseenCount == 1 ? "" : "s") to review"
                             : "Radar: all caught up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10)).foregroundColor(.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)

            // Offline queue, only when relevant
            if !queue.items.isEmpty {
                railCard {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.up").foregroundColor(.statusAmber)
                        Text("\(queue.items.count) queued commit\(queue.items.count == 1 ? "" : "s") waiting for network")
                            .font(.system(size: 12)).foregroundColor(.textPrimary)
                    }
                }
            }

            // Regulation KPIs, compact
            Text("EU REGULATION")
                .font(.system(size: 11, weight: .semibold)).tracking(0.7)
                .foregroundColor(.textSecondary)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                miniKPI("\(store.inForceCount)", "In force", .statusGreen)
                miniKPI("\(store.upcomingCount)", "Upcoming", .statusAmber)
                miniKPI("\(store.blockedCount)", "Blocked", .statusRed)
                miniKPI("\(store.negotiations.count)", "Trilogue", .accentNavy)
            }
            Button { if let s = primarySite { openSection(s, .tracker) } } label: {
                Text("Open the tracker →")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.accentNavy)
            }
            .buttonStyle(.plain)
        }
        .task {
            guard SupabaseAPI.isConfigured() else { waitingCount = nil; return }
            waitingCount = try? await SupabaseAPI.listReviewQueue().count
        }
    }

    private func railCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.bgCard))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func miniKPI(_ value: String, _ label: String, _ accent: Color) -> some View {
        railCard {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(accent)
                Text(label).font(.system(size: 10.5)).foregroundColor(.textSecondary)
            }
        }
    }
}

// MARK: - Add-project sheet

struct AddProjectSheet: View {
    @EnvironmentObject var store: CockpitStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var repo = ""
    @State private var cms = ""
    @State private var netlifyID = ""
    @State private var contentPaths = "content/articles/"

    private var slugID: String { slugify(name) }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !slugID.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add project")
                .font(.system(size: 18, weight: .bold)).foregroundColor(.textPrimary)
            Text("A project is a website you run: its repo powers the Content tab, Netlify the Deploys tab. Only the name is required — add the rest anytime.")
                .font(.callout).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Name", "My new site", $name)
            field("Site URL", "https://example.com", $url)
            field("GitHub repo (owner/name)", "user/repo", $repo)
            field("CMS URL (Sveltia admin)", "https://example.com/admin/", $cms)
            field("Netlify site ID", "Site configuration → General → Site ID", $netlifyID)
            field("Content paths (comma-separated)", "content/articles/", $contentPaths)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add project") {
                    let paths = contentPaths.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    store.addUserSite(SiteProject(
                        id: slugID,
                        name: name.trimmingCharacters(in: .whitespaces),
                        url: url.isEmpty ? nil : url,
                        cms_url: cms.isEmpty ? nil : cms,
                        repo: repo.isEmpty ? nil : repo,
                        default_branch: "main",
                        netlify_site_id: netlifyID.isEmpty ? nil : netlifyID,
                        content_paths: paths.isEmpty ? nil : paths))
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.accentNavySolid)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(.textSecondary)
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Beta badge (Home greeting + design previews)

/// Small capsule marking the beta channel. Version text comes from the
/// bundle, so tagged releases show their real number automatically.
struct BetaBadge: View {
    var body: some View {
        Text("BETA \(AppVersion.current)")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(.accentNavy)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.navyTint))
            .overlay(Capsule().stroke(Color.cardBorder, lineWidth: 1))
            .help("You are running the LexCockpit beta channel")
    }
}
