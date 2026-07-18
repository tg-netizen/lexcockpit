import Foundation
import SwiftUI

/// Single source of truth for the cockpit. Pulls the same public JSON feeds the
/// website uses, so the app is always in sync with what you publish. Projects
/// come from a local projects.json (your own work — not a public feed).
@MainActor
final class CockpitStore: ObservableObject {
    @Published var regulations: [Regulation] = []
    @Published var pipeline: [PipelineItem] = []
    @Published var negotiations: [Negotiation] = []
    @Published var cases: [EnforcementCase] = []
    @Published var projects: [Project] = []

    @Published var lastFetched: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Point this at production, or a local `python3 -m http.server` while developing.
    private let base = "https://lexdigestglobal.com/data/"

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        do {
            async let t = fetch("tracker.json", as: TrackerFeed.self)
            async let p = fetch("pipeline.json", as: PipelineFeed.self)
            async let g = fetch("trilogue.json", as: TrilogueFeed.self)
            async let e = fetch("enforcement.json", as: EnforcementFeed.self)
            let (tf, pf, gf, ef) = try await (t, p, g, e)
            regulations = tf.data
            lastFetched = tf.meta?.lastFetched ?? ""
            pipeline    = pf.items
            negotiations = gf.negotiations
            cases       = ef.cases
        } catch {
            errorMessage = "Could not load feeds: \(error.localizedDescription)"
        }
        loadProjectsFromBundle()
        isLoading = false
    }

    private func fetch<T: Decodable>(_ file: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: base + file) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Loads the bundled sample projects.json on first launch (if none loaded yet).
    func loadProjectsFromBundle() {
        guard projects.isEmpty,
              let url = Bundle.main.url(forResource: "projects", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pf = try? JSONDecoder().decode(ProjectsFile.self, from: data) else { return }
        projects = pf.projects
    }

    /// Load your real projects.json (generate it with scripts/build-projects.js).
    func loadProjects(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let pf = try? JSONDecoder().decode(ProjectsFile.self, from: data) else {
            errorMessage = "Could not read that projects.json"
            return
        }
        projects = pf.projects
    }

    // Convenience counts for the dashboard
    var inForceCount: Int { regulations.filter { $0.status == .applied }.count }
    var upcomingCount: Int { regulations.filter { $0.status == .upcoming }.count }
    var blockedCount: Int { regulations.filter { $0.status == .blocked }.count }
    var draftCount: Int { projects.filter { ($0.status ?? "") == "draft" }.count }
    var publishedCount: Int { projects.filter { ($0.status ?? "") == "published" }.count }
}
