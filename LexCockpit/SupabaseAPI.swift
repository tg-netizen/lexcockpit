import Foundation

// MARK: - Keychain accounts (URL + publishable/anon key — never service_role)

extension Keychain {
    static let supabaseURL = "supabase_url"
    static let supabaseAnonKey = "supabase_anon_key"

    /// Default LexCockpit project URL when none is saved yet.
    static let defaultSupabaseURL = "https://fstoenrocfyzdsgmiknj.supabase.co"
}

// MARK: - Feed text arrives HTML-encoded

extension String {
    /// Decode the HTML entities RSS puts in titles.
    ///
    /// A real title in the queue on 9 August 2026 read "countermeasure
    /// sanctions list &#038; adds additional controls". The outlet meant "&".
    /// Left alone that string reaches the screen raw — and from the screen it
    /// reaches a published brief by copy and paste, which is exactly the class
    /// of error this project exists to prevent.
    ///
    /// Two passes at most, because some feeds encode twice (`&amp;#038;`), and
    /// bounded so no input can loop. NSAttributedString would also do this, but
    /// it drags in a full HTML parser that must run on the main thread.
    var decodingHTMLEntities: String {
        var s = self
        var pass = 0
        while pass < 2, s.contains("&") {
            let next = String.decodeEntitiesOnce(s)
            if next == s { break }
            s = next
            pass += 1
        }
        return s
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "euro": "€", "pound": "£",
        "deg": "°", "middot": "·", "bull": "•", "shy": ""
    ]

    private static func decodeEntitiesOnce(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&" else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            /* An entity is short. Scanning further than this would let a bare
               "&" in one sentence swallow the punctuation of the next. */
            var j = s.index(after: i)
            var body = ""
            var closed = false
            while j < s.endIndex, body.count < 8 {
                if s[j] == ";" { closed = true; break }
                body.append(s[j]); j = s.index(after: j)
            }
            if closed, !body.isEmpty {
                if body.hasPrefix("#") {
                    let digits = body.dropFirst()
                    let value = (digits.first == "x" || digits.first == "X")
                        ? UInt32(digits.dropFirst(), radix: 16)
                        : UInt32(digits, radix: 10)
                    if let v = value, let u = Unicode.Scalar(v) {
                        out.append(Character(u)); i = s.index(after: j); continue
                    }
                } else if let named = String.namedEntities[body.lowercased()] {
                    out.append(named); i = s.index(after: j); continue
                }
            }
            out.append("&"); i = s.index(after: i)
        }
        return out
    }
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

    /// Always render these, never the raw columns — see `decodingHTMLEntities`.
    var displayTitle: String { title.decodingHTMLEntities }
    var displaySnippet: String { (snippet ?? "").decodingHTMLEntities }

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
