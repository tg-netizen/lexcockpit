import Foundation
import SwiftUI

// MARK: - Per-feed identity + failure

enum FeedKind: String, CaseIterable, Identifiable {
    case tracker, pipeline, trilogue, enforcement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tracker:     return "Tracker"
        case .pipeline:    return "Pipeline"
        case .trilogue:    return "Trilogue"
        case .enforcement: return "Enforcement"
        }
    }
    var file: String { rawValue + ".json" }
}

struct FeedFailure: Equatable {
    let summary: String     // one legible line for the card
    let detail: String      // developer-facing underlying error
}

enum FeedError: Error {
    case http(Int, hint: String?)
    case notJSON(preview: String)
}

// MARK: - Store

/// Single source of truth. Each feed loads INDEPENDENTLY — one broken feed
/// shows an inline error card in its own section and never blocks the rest.
@MainActor
final class CockpitStore: ObservableObject {
    @Published var regulations: [Regulation] = []
    @Published var pipeline: [PipelineItem] = []
    @Published var negotiations: [Negotiation] = []
    @Published var cases: [EnforcementCase] = []
    @Published var projects: [Project] = []
    @Published var sites: [SiteProject] = []

    @Published var lastFetched: String = ""
    @Published var isLoading = false
    /// projects.json problems only — feed problems are per-feed below.
    @Published var errorMessage: String?

    @Published var feedErrors: [FeedKind: FeedFailure] = [:]
    /// Feeds that have loaded successfully at least once — lets views
    /// distinguish "genuinely empty" from "failed or not yet loaded".
    @Published var feedLoaded: Set<FeedKind> = []

    // MARK: Settings (non-secret → UserDefaults; tokens live in the Keychain)

    static let defaultBase = "https://lexdigestglobal.com/data/"

    var feedBase: String {
        let raw = UserDefaults.standard.string(forKey: "feedBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = raw.isEmpty ? Self.defaultBase : raw
        return base.hasSuffix("/") ? base : base + "/"
    }

    /// 0 = manual only; default 15 when never set.
    var refreshMinutes: Int {
        if UserDefaults.standard.object(forKey: "refreshMinutes") == nil { return 15 }
        return UserDefaults.standard.integer(forKey: "refreshMinutes")
    }

    // MARK: Loading

    func loadAll() async {
        isLoading = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadTracker() }
            group.addTask { await self.loadPipeline() }
            group.addTask { await self.loadTrilogue() }
            group.addTask { await self.loadEnforcement() }
        }
        loadProjectsFromBundle()
        isLoading = false
    }

    private func loadTracker() async {
        do {
            let feed: TrackerFeed = try await fetch(.tracker)
            regulations = feed.data
            lastFetched = feed.meta?.lastFetched ?? ""
            markLoaded(.tracker)
        } catch { record(.tracker, error) }
    }

    private func loadPipeline() async {
        do {
            let feed: PipelineFeed = try await fetch(.pipeline)
            pipeline = feed.items
            markLoaded(.pipeline)
        } catch { record(.pipeline, error) }
    }

    private func loadTrilogue() async {
        do {
            let feed: TrilogueFeed = try await fetch(.trilogue)
            negotiations = feed.negotiations
            markLoaded(.trilogue)
        } catch { record(.trilogue, error) }
    }

    private func loadEnforcement() async {
        do {
            let feed: EnforcementFeed = try await fetch(.enforcement)
            cases = feed.cases
            markLoaded(.enforcement)
        } catch { record(.enforcement, error) }
    }

    private func markLoaded(_ kind: FeedKind) {
        feedLoaded.insert(kind)
        feedErrors[kind] = nil
    }

    private func record(_ kind: FeedKind, _ error: Error) {
        feedErrors[kind] = Self.describe(error, base: feedBase)
    }

    private func fetch<T: Decodable>(_ kind: FeedKind) async throws -> T {
        guard let url = URL(string: feedBase + kind.file) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let hint = http.statusCode == 401
                ? "The site is behind Netlify password protection. Disable it, or point the app at a local copy: Settings (gear) → Feed base URL, e.g. http://localhost:8899/data/ while running `python3 -m http.server 8899` in the website repo."
                : nil
            throw FeedError.http(http.statusCode, hint: hint)
        }
        let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
        if head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            throw FeedError.notJSON(preview: head)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Error rendering

    static func describe(_ error: Error, base: String) -> FeedFailure {
        switch error {
        case FeedError.http(let code, let hint):
            let summary = code == 401 ? "site is password-protected (HTTP 401)" : "server returned HTTP \(code)"
            var detail = "GET \(base)… → HTTP \(code)."
            if let hint = hint { detail += "\n\n\(hint)" }
            return FeedFailure(summary: summary, detail: detail)
        case FeedError.notJSON(let preview):
            return FeedFailure(summary: "got an HTML page, not JSON",
                               detail: "The response body starts with:\n\(preview)")
        case let decoding as DecodingError:
            return FeedFailure(summary: "feed format changed (decoding failed)",
                               detail: Self.describeDecoding(decoding))
        case let urlErr as URLError:
            return FeedFailure(summary: "network error",
                               detail: urlErr.localizedDescription)
        default:
            return FeedFailure(summary: "could not load",
                               detail: String(describing: error))
        }
    }

    private static func describeDecoding(_ e: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "Missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(let type, let ctx):
            return "Type mismatch (expected \(type)) at \(path(ctx)): \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "Null where \(type) expected at \(path(ctx))"
        case .dataCorrupted(let ctx):
            return "Corrupted data at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: e)
        }
    }

    // MARK: Projects file

    /// Resource bundle: Bundle.module under `swift run`, Bundle.main in Xcode.
    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    /// Loads the bundled sample projects.json on first launch (if none loaded yet).
    func loadProjectsFromBundle() {
        guard projects.isEmpty,
              let url = resourceBundle.url(forResource: "projects", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pf = try? JSONDecoder().decode(ProjectsFile.self, from: data) else { return }
        projects = pf.projects
        if sites.isEmpty { sites = pf.sites ?? [] }
    }

    /// Load your real projects.json (generate it with scripts/build-projects.js).
    func loadProjects(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let pf = try? JSONDecoder().decode(ProjectsFile.self, from: data) else {
            errorMessage = "Could not read that projects.json"
            return
        }
        projects = pf.projects
        if let s = pf.sites, !s.isEmpty { sites = s }
    }

    // Convenience counts for the dashboard
    var inForceCount: Int { regulations.filter { $0.status == .applied }.count }
    var upcomingCount: Int { regulations.filter { $0.status == .upcoming }.count }
    var blockedCount: Int { regulations.filter { $0.status == .blocked }.count }
    var draftCount: Int { projects.filter { ($0.status ?? "") == "draft" }.count }
    var publishedCount: Int { projects.filter { ($0.status ?? "") == "published" }.count }
}
