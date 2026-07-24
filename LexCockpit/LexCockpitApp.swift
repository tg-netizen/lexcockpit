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
    @State private var selection: SidebarSelection? = .section(.dashboard)
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Cockpit") {
                    row(.dashboard)
                }
                Section("Projects") {
                    ForEach(store.sites) { site in
                        NavigationLink(value: SidebarSelection.site(site.id)) {
                            Label(site.name, systemImage: "globe")
                        }
                    }
                    if store.sites.isEmpty {
                        Text("No projects yet")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section("Topics") {
                    row(.tracker)
                    row(.pipeline)
                    row(.trilogue)
                    row(.enforcement)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 280)
            .navigationTitle("LexCockpit")
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await store.loadAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh feeds")
                        .disabled(store.isLoading)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("API tokens (stored in the macOS Keychain)")
                    }
                    ToolbarItem(placement: .automatic) {
                        if store.isLoading { ProgressView().controlSize(.small) }
                    }
                }
        }
        .task { await store.loadAll() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .background(Color.brandCream)
    }

    private func row(_ s: CockpitSection) -> some View {
        NavigationLink(value: SidebarSelection.section(s)) {
            Label(s.title, systemImage: s.icon)
        }
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
                Text("Project not found").foregroundColor(.secondary)
            }
        }
    }
}
