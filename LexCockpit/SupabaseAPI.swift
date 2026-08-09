import Foundation

// MARK: - Keychain accounts (URL + publishable/anon key — never service_role)

extension Keychain {
    static let supabaseURL = "supabase_url"
    static let supabaseAnonKey = "supabase_anon_key"

    /// Default LexCockpit project URL when none is saved yet.
    static let defaultSupabaseURL = "https://fstoenrocfyzdsgmiknj.supabase.co"
}

// MARK: - Review waiting list (free scan-only pipeline)

struct ReviewQueueItem: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let source_url: String?
    let snippet: String?
    let published_at: String?
    let relevance_score: Double?
    let relevance_reason: String?
    let status: String?
    let created_at: String?
    let source_name: String?
    let source_slug: String?
    let region: String?

    var scoreLabel: String {
        guard let s = relevance_score else { return "—" }
        return String(format: "%.0f%%", s * 100)
    }

    var openURL: URL? {
        guard let raw = source_url, let url = URL(string: raw) else { return nil }
        return url
    }
}

enum SupabaseAPI {
    static func configuredURL() -> String {
        let saved = Keychain.get(Keychain.supabaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Keychain.defaultSupabaseURL : saved
    }

    static func isConfigured() -> Bool {
        Keychain.has(Keychain.supabaseAnonKey)
    }

    /// GET /rest/v1/review_queue — free scan-only waiting list.
    static func listReviewQueue() async throws -> [ReviewQueueItem] {
        guard let key = Keychain.get(Keychain.supabaseAnonKey), !key.isEmpty else {
            throw APIError.noToken("Supabase anon")
        }
        let base = configuredURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: "\(base)/rest/v1/review_queue") else {
            throw APIError.badURL
        }
        /* Named columns instead of `*`: a column later added to the view then
           cannot start arriving in the app unannounced. And a hard limit — the
           waiting list only grows, and fetching every row ever queued is not
           something a sidebar list should do. */
        comps.queryItems = [
            URLQueryItem(name: "select", value:
                "id,title,source_url,snippet,published_at,relevance_score,"
                + "relevance_reason,status,created_at,source_name,source_slug,region"),
            URLQueryItem(name: "order", value: "relevance_score.desc.nullslast,created_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = comps.url else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let started = Date()
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            diagRecord("supabase", "GET review_queue", status: "offline", start: started, ok: false)
            throw error
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        diagRecord("supabase", "GET review_queue", status: "\(code)", start: started, ok: code < 300)
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data.prefix(240), encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([ReviewQueueItem].self, from: data)
    }

    /// What the most recent ingest run believed it had queued.
    ///
    /// This exists for one comparison. On 9 August 2026 the run reported 34
    /// items queued and the waiting list returned none, because the anon RLS
    /// policies were missing and PostgREST answered 200 with `[]`. Neither
    /// side was wrong on its own; only the disagreement was informative, and
    /// this app is the only thing in the stack that sees both.
    ///
    /// Failure is silent by design — a missing telemetry table must never
    /// stop the queue from loading. The caller treats nil as "no opinion".
    static func lastRunItemsQueued() async throws -> Int? {
        guard let key = Keychain.get(Keychain.supabaseAnonKey), !key.isEmpty else { return nil }
        let base = configuredURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: "\(base)/rest/v1/pipeline_runs") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "select", value: "items_queued,started_at,status"),
            URLQueryItem(name: "order", value: "started_at.desc"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let started = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        diagRecord("supabase", "GET pipeline_runs", status: "\(code)", start: started, ok: code < 300)
        guard (200..<300).contains(code) else { return nil }

        struct Run: Decodable { let items_queued: Int? }
        return (try? JSONDecoder().decode([Run].self, from: data))?.first?.items_queued
    }
}
