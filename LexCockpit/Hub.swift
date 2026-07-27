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

// MARK: - Project hub (the app's home: your projects first, digest second)

struct ProjectHubView: View {
    @EnvironmentObject var store: CockpitStore
    var navigate: (SidebarSelection) -> Void
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projects")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Everything you run — status at a glance, one click to work.")
                        .font(.callout).foregroundColor(.textSecondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
                          spacing: 16) {
                    ForEach(store.sites) { site in
                        ProjectTile(site: site,
                                    isUserAdded: store.isUserSite(site.id),
                                    open: { navigate(.site(site.id)) },
                                    remove: { store.removeUserSite(site.id) })
                    }
                    AddProjectTile { showAdd = true }
                }

                digest
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgPage)
        .sheet(isPresented: $showAdd) { AddProjectSheet() }
    }

    // Regulatory digest — secondary, compact.
    @ViewBuilder private var digest: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EU regulation at a glance")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.textPrimary)
                .padding(.top, 6)

            LazyVGrid(columns: grid(min: 150), spacing: 12) {
                StatTile(value: "\(store.inForceCount)", label: "Rules in force", accent: .statusGreen)
                StatTile(value: "\(store.upcomingCount)", label: "Upcoming", accent: .statusAmber)
                StatTile(value: "\(store.blockedCount)", label: "Blocked / in flux", accent: .statusRed)
                StatTile(value: "\(store.negotiations.count)", label: "In trilogue")
            }

            let upcoming = store.regulations
                .filter { $0.status == .upcoming && ($0.applicationDate ?? "") >= todayISO() }
                .sorted { ($0.applicationDate ?? "") < ($1.applicationDate ?? "") }
                .prefix(4)

            FeedStateView(kind: .tracker,
                          emptyText: "The tracker feed loaded but lists no upcoming deadlines.",
                          isEmpty: upcoming.isEmpty)

            if !upcoming.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(upcoming)) { r in
                        Card {
                            HStack {
                                Text(prettyDate(r.applicationDate))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.textSecondary)
                                    .frame(width: 106, alignment: .leading)
                                Text(r.name).fontWeight(.semibold).foregroundColor(.textPrimary)
                                Spacer()
                                pill(for: r.status)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tiles

struct ProjectTile: View {
    let site: SiteProject
    let isUserAdded: Bool
    var open: () -> Void
    var remove: () -> Void

    @State private var hovering = false
    @StateObject private var model: WorkspaceModel

    init(site: SiteProject, isUserAdded: Bool,
         open: @escaping () -> Void, remove: @escaping () -> Void) {
        self.site = site
        self.isUserAdded = isUserAdded
        self.open = open
        self.remove = remove
        _model = StateObject(wrappedValue: WorkspaceModel.shared(for: site))
    }

    private var initials: String {
        String(site.name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentNavy)
                        Text(initials)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        if let url = site.url {
                            Text(url.replacingOccurrences(of: "https://", with: ""))
                                .font(.system(size: 11.5))
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if let deploy = model.deploys.first {
                        Circle().fill(deployColor(deploy.stateKind))
                            .frame(width: 7, height: 7)
                        Text("\(deploy.state.capitalized) · \(relativeTime(deploy.created_at))")
                            .font(.system(size: 11)).foregroundColor(.textSecondary)
                    } else if let repo = site.repo {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 9)).foregroundColor(.textSecondary)
                        Text(repo).font(.system(size: 11)).foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !model.contentEntries.isEmpty {
                        let drafts = model.contentEntries.filter(\.isDraft).count
                        Text("\(model.contentEntries.count - drafts) live · \(drafts) drafts")
                            .font(.system(size: 11)).foregroundColor(.textSecondary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.bgCard)
                    .shadow(color: .black.opacity(hovering ? 0.10 : 0.04),
                            radius: hovering ? 10 : 3, x: 0, y: hovering ? 4 : 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(hovering ? Color.accentNavy.opacity(0.45) : Color.cardBorder, lineWidth: 1))
            .scaleEffect(hovering ? 1.012 : 1.0)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if isUserAdded {
                Button("Remove project", role: .destructive, action: remove)
            }
            if let urlStr = site.url, let url = URL(string: urlStr) {
                Button("Open site in browser") { NSWorkspace.shared.open(url) }
            }
        }
        .task {
            if model.deploys.isEmpty, Keychain.has(Keychain.netlifyPAT),
               !(site.netlify_site_id ?? "").isEmpty {
                await model.loadDeploys()
            }
        }
    }
}

struct AddProjectTile: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(hovering ? .accentNavy : .textSecondary)
                Text("Add project")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(hovering ? .accentNavy : .textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 106)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.bgCard.opacity(hovering ? 1 : 0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(hovering ? Color.accentNavy.opacity(0.5) : Color.cardBorder,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            )
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add another website project (repo, CMS, Netlify)")
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
                .buttonStyle(.borderedProminent).tint(.accentNavy)
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
