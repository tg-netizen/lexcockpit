import SwiftUI

@main
struct LexCockpitApp: App {
    @StateObject private var store = CockpitStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }
    }
}

enum CockpitSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, projects, tracker, pipeline, trilogue, enforcement
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .projects:    return "Projects"
        case .tracker:     return "Tracker"
        case .pipeline:    return "Pipeline"
        case .trilogue:    return "Trilogue"
        case .enforcement: return "Enforcement"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2"
        case .projects:    return "folder"
        case .tracker:     return "calendar"
        case .pipeline:    return "tray.full"
        case .trilogue:    return "person.3"
        case .enforcement: return "eurosign.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: CockpitStore
    @State private var selection: CockpitSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Cockpit") {
                    row(.dashboard)
                    row(.projects)
                }
                Section("Topics") {
                    row(.tracker)
                    row(.pipeline)
                    row(.trilogue)
                    row(.enforcement)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
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
                        if store.isLoading { ProgressView().controlSize(.small) }
                    }
                }
        }
        .task { await store.loadAll() }
        .background(Color.brandCream)
    }

    private func row(_ s: CockpitSection) -> some View {
        NavigationLink(value: s) {
            Label(s.title, systemImage: s.icon)
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selection ?? .dashboard {
        case .dashboard:   DashboardView()
        case .projects:    ProjectsView()
        case .tracker:     TrackerView()
        case .pipeline:    PipelineView()
        case .trilogue:    TrilogueView()
        case .enforcement: EnforcementView()
        }
    }
}
