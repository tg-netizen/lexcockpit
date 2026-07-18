import Foundation

// MARK: - Tracker (data/tracker.json)

struct TrackerFeed: Decodable {
    let meta: TrackerMeta?
    let data: [Regulation]
}

struct TrackerMeta: Decodable {
    let lastFetched: String?
    let fetchSuccess: Bool?
}

enum RegStatus: String {
    case applied  = "IN FORCE"
    case upcoming = "UPCOMING"
    case blocked  = "BLOCKED"
}

struct Regulation: Decodable, Identifiable {
    let id: String
    let celex: String?
    let name: String
    let area: String?
    let date: String?
    let applicationDate: String?
    let dateInForce: String?
    let statusOverride: String?
    let statusNote: String?
    let sourceUrl: String?
    let analysis_url: String?
    let transitionPhases: [Phase]?

    var status: RegStatus {
        if (statusOverride ?? "").uppercased() == "BLOCKED" { return .blocked }
        guard let ad = applicationDate, ad.count >= 10 else { return .upcoming }
        return ad <= todayISO() ? .applied : .upcoming
    }
}

struct Phase: Decodable, Identifiable {
    let date: String
    let label: String
    var id: String { date + "|" + label }
}

// MARK: - Pipeline (data/pipeline.json)

struct PipelineFeed: Decodable {
    let generated_at: String?
    let items: [PipelineItem]
}

struct PipelineItem: Decodable, Identifiable {
    let id: String
    let title: String
    let type: String?
    let status: String?
    let planned_quarter: String?
    let responsible_dg: String?
    let priority: String?
    let brief: String?
    let have_your_say_url: String?
}

// MARK: - Trilogue (data/trilogue.json)

struct TrilogueFeed: Decodable {
    let generated_at: String?
    let negotiations: [Negotiation]
}

struct Negotiation: Decodable, Identifiable {
    let id: String
    let title: String
    let current_stage: String?
    let next_session: String?
    let sessions_held: Int?
    let council_presidency: String?
    let ep_rapporteur: String?
    let sticking_points: [String]?
    let last_update: String?
    let oeil_url: String?
    let note: String?
}

// MARK: - Enforcement (data/enforcement.json)

struct EnforcementFeed: Decodable {
    let generated_at: String?
    let cases: [EnforcementCase]
}

struct EnforcementCase: Decodable, Identifiable {
    let id: String
    let date: String?
    let regulation: String?
    let authority: String?
    let jurisdiction: String?
    let entity: String?
    let sector: String?
    let amount_eur: Double?
    let conduct: String?
    let source_url: String?
    let final: Bool?
}

// MARK: - Projects (local projects.json — your own work)

struct ProjectsFile: Decodable {
    let projects: [Project]
}

struct Project: Decodable, Identifiable {
    let id: String
    let title: String
    let type: String?
    let status: String?          // draft / scheduled / published
    let date: String?
    let scheduledPublishAt: String?
    let topic: String?
    let url: String?
}

// MARK: - Helpers

func todayISO() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
}

func prettyDate(_ iso: String?) -> String {
    guard let iso = iso, iso.count >= 10 else { return iso ?? "—" }
    let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    let parts = iso.prefix(10).split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), m >= 1, m <= 12 else { return String(iso.prefix(10)) }
    return "\(parts[2]) \(months[m - 1]) \(parts[0])"
}

func formatEuro(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    if v >= 1_000_000_000 { return String(format: "€%.1fB", v / 1_000_000_000) }
    if v >= 1_000_000     { return String(format: "€%.1fM", v / 1_000_000) }
    if v >= 1_000         { return String(format: "€%.0fk", v / 1_000) }
    return String(format: "€%.0f", v)
}
