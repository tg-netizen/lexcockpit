import Foundation

// MARK: - Decoding armor
//
// The feeds are hand-edited JSON + generated data; the app must never lose a
// whole dashboard section to one malformed item or a renamed optional field.
// Strategy: every feed decodes through LossyArray (bad items are skipped, the
// rest render) and every non-identity field is optional with safe fallbacks.

/// Swallows any JSON value — used to skip past malformed array elements.
struct AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        let c = try? decoder.singleValueContainer()
        if let c = c {
            if c.decodeNil() { return }
            if (try? c.decode(Bool.self)) != nil { return }
            if (try? c.decode(Double.self)) != nil { return }
            if (try? c.decode(String.self)) != nil { return }
            if (try? c.decode([AnyJSON].self)) != nil { return }
            if (try? c.decode([String: AnyJSON].self)) != nil { return }
        }
    }
}

/// Array that drops undecodable elements instead of failing the whole feed.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(AnyJSON.self)   // consume + skip
            }
        }
    }
}

/// Accepts "2026-07-01", full ISO8601, or missing → normalized yyyy-MM-dd
/// prefix (all app logic compares date strings lexicographically).
func normalizedDate(_ raw: String?) -> String? {
    guard let raw = raw, raw.count >= 10 else { return raw }
    return String(raw.prefix(10))
}

// MARK: - Tracker (data/tracker.json)

struct TrackerFeed: Decodable {
    let meta: TrackerMeta?
    let data: [Regulation]

    enum CodingKeys: String, CodingKey { case meta, data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try? c.decodeIfPresent(TrackerMeta.self, forKey: .meta)
        data = (try? c.decode(LossyArray<Regulation>.self, forKey: .data))?.elements ?? []
    }
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

    enum CodingKeys: String, CodingKey {
        case id, celex, name, area, date, applicationDate, dateInForce
        case statusOverride, statusNote, sourceUrl, analysis_url, transitionPhases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        celex = try? c.decodeIfPresent(String.self, forKey: .celex)
        let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        name = rawName ?? "Untitled regulation"
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)
            ?? celex ?? rawName ?? UUID().uuidString
        area = try? c.decodeIfPresent(String.self, forKey: .area)
        date = normalizedDate(try? c.decodeIfPresent(String.self, forKey: .date))
        applicationDate = normalizedDate(try? c.decodeIfPresent(String.self, forKey: .applicationDate))
        dateInForce = normalizedDate(try? c.decodeIfPresent(String.self, forKey: .dateInForce))
        statusOverride = try? c.decodeIfPresent(String.self, forKey: .statusOverride)
        statusNote = try? c.decodeIfPresent(String.self, forKey: .statusNote)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
        analysis_url = try? c.decodeIfPresent(String.self, forKey: .analysis_url)
        transitionPhases = (try? c.decodeIfPresent(LossyArray<Phase>.self, forKey: .transitionPhases))??.elements
    }

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

    enum CodingKeys: String, CodingKey { case date, label }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = normalizedDate((try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil) ?? ""
        label = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? "—"
    }
}

// MARK: - Pipeline (data/pipeline.json)

struct PipelineFeed: Decodable {
    let generated_at: String?
    let items: [PipelineItem]

    enum CodingKeys: String, CodingKey { case generated_at, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated_at = try? c.decodeIfPresent(String.self, forKey: .generated_at)
        items = (try? c.decode(LossyArray<PipelineItem>.self, forKey: .items))?.elements ?? []
    }
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

    enum CodingKeys: String, CodingKey {
        case id, title, type, status, planned_quarter, responsible_dg, priority, brief, have_your_say_url
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = rawTitle ?? "Untitled file"
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? rawTitle ?? UUID().uuidString
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        planned_quarter = try? c.decodeIfPresent(String.self, forKey: .planned_quarter)
        responsible_dg = try? c.decodeIfPresent(String.self, forKey: .responsible_dg)
        priority = try? c.decodeIfPresent(String.self, forKey: .priority)
        brief = try? c.decodeIfPresent(String.self, forKey: .brief)
        have_your_say_url = try? c.decodeIfPresent(String.self, forKey: .have_your_say_url)
    }
}

// MARK: - Trilogue (data/trilogue.json)

struct TrilogueFeed: Decodable {
    let generated_at: String?
    let negotiations: [Negotiation]

    enum CodingKeys: String, CodingKey { case generated_at, negotiations }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated_at = try? c.decodeIfPresent(String.self, forKey: .generated_at)
        negotiations = (try? c.decode(LossyArray<Negotiation>.self, forKey: .negotiations))?.elements ?? []
    }
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

    enum CodingKeys: String, CodingKey {
        case id, title, current_stage, next_session, sessions_held
        case council_presidency, ep_rapporteur, sticking_points, last_update, oeil_url, note
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = rawTitle ?? "Untitled negotiation"
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? rawTitle ?? UUID().uuidString
        current_stage = try? c.decodeIfPresent(String.self, forKey: .current_stage)
        next_session = try? c.decodeIfPresent(String.self, forKey: .next_session)
        sessions_held = try? c.decodeIfPresent(Int.self, forKey: .sessions_held)
        council_presidency = try? c.decodeIfPresent(String.self, forKey: .council_presidency)
        ep_rapporteur = try? c.decodeIfPresent(String.self, forKey: .ep_rapporteur)
        sticking_points = (try? c.decodeIfPresent(LossyArray<String>.self, forKey: .sticking_points))??.elements
        last_update = normalizedDate(try? c.decodeIfPresent(String.self, forKey: .last_update))
        oeil_url = try? c.decodeIfPresent(String.self, forKey: .oeil_url)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - Enforcement (data/enforcement.json)

struct EnforcementFeed: Decodable {
    let generated_at: String?
    let cases: [EnforcementCase]

    enum CodingKeys: String, CodingKey { case generated_at, cases }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated_at = try? c.decodeIfPresent(String.self, forKey: .generated_at)
        cases = (try? c.decode(LossyArray<EnforcementCase>.self, forKey: .cases))?.elements ?? []
    }
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

    enum CodingKeys: String, CodingKey {
        case id, date, regulation, authority, jurisdiction, entity, sector, amount_eur, conduct, source_url, final
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        date = normalizedDate(try? c.decodeIfPresent(String.self, forKey: .date))
        regulation = try? c.decodeIfPresent(String.self, forKey: .regulation)
        authority = try? c.decodeIfPresent(String.self, forKey: .authority)
        jurisdiction = try? c.decodeIfPresent(String.self, forKey: .jurisdiction)
        entity = try? c.decodeIfPresent(String.self, forKey: .entity)
        sector = try? c.decodeIfPresent(String.self, forKey: .sector)
        // amount may arrive as number or "1234" string
        if let d = try? c.decodeIfPresent(Double.self, forKey: .amount_eur) {
            amount_eur = d
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .amount_eur)) ?? nil {
            amount_eur = Double(s.replacingOccurrences(of: ",", with: ""))
        } else {
            amount_eur = nil
        }
        conduct = try? c.decodeIfPresent(String.self, forKey: .conduct)
        source_url = try? c.decodeIfPresent(String.self, forKey: .source_url)
        final = try? c.decodeIfPresent(Bool.self, forKey: .final)
    }
}

// MARK: - Projects (local projects.json — your own work)

struct ProjectsFile: Decodable {
    let projects: [Project]
    let sites: [SiteProject]?      // site workspaces (CMS / deploys / repo / content)
}

/// One website project = one workspace (Overview · Content · CMS · Deploys · Repo).
/// Secrets never live here — tokens are in the macOS Keychain.
struct SiteProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String?               // https://lexdigestglobal.com
    let cms_url: String?           // https://lexdigestglobal.com/admin/
    let repo: String?              // "owner/name" on GitHub
    let default_branch: String?    // defaults to main
    let netlify_site_id: String?   // Netlify API site id
    let content_paths: [String]?   // ["content/articles/", …]
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

func parseISO(_ s: String) -> Date? {
    guard s.count >= 10 else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.date(from: String(s.prefix(10)))
}

func isoString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: d)
}

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
