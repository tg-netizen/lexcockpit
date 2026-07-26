import SwiftUI
import AppKit

@main
struct LexCockpitApp: App {
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
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }
    }
}

enum CockpitSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, tracker, pipeline, trilogue, enforcement
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .tracker:     return "Tracker"
        case .pipeline:    return "Pipeline"
        case .trilogue:    return "Trilogue"
        case .enforcement: return "Enforcement"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2"
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
    @State private var columns = NavigationSplitViewVisibility.automatic

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
        .task {
            await store.loadAll()
            await updates.check()
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
                Text("v\(AppVersion.current)")
                    .font(.caption2).foregroundColor(.textSecondary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            .padding(.vertical, 10)
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
        case .section(.dashboard):   DashboardView()
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
