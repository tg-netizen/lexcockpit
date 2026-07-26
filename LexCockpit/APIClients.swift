import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case noToken(String)
    case badURL
    case http(Int, String)
    case conflict            // GitHub SHA mismatch — file changed remotely

    var errorDescription: String? {
        switch self {
        case .noToken(let which): return "No \(which) token yet — add it in Settings (gear icon)."
        case .badURL:             return "Invalid URL."
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .conflict:           return "File changed on GitHub since you opened it."
        }
    }
}

// MARK: - Netlify

struct NetlifyDeploy: Decodable, Identifiable {
    let id: String
    let state: String            // ready / building / enqueued / error / …
    let branch: String?
    let title: String?           // commit message
    let created_at: String?
    let deploy_time: Int?        // seconds
    let error_message: String?

    /// green = published, yellow = in progress, red = failed
    var stateKind: String {
        switch state {
        case "ready", "current": return "good"
        case "error", "failed":  return "bad"
        default:                 return "busy"
        }
    }
}

enum NetlifyAPI {
    static func deploys(siteId: String) async throws -> [NetlifyDeploy] {
        guard let token = Keychain.get(Keychain.netlifyPAT) else { throw APIError.noToken("Netlify") }
        guard !siteId.isEmpty,
              let url = URL(string: "https://api.netlify.com/api/v1/sites/\(siteId)/deploys?per_page=10")
        else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode([NetlifyDeploy].self, from: data)
    }

    /// POST the saved build-hook URL (stored in the Keychain — it embeds a token).
    static func triggerBuildHook() async throws {
        guard let hook = Keychain.get(Keychain.netlifyBuildHook), let url = URL(string: hook)
        else { throw APIError.noToken("Netlify build-hook") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
    }
}

// MARK: - GitHub

struct GHCommit: Decodable, Identifiable {
    struct Inner: Decodable {
        struct Author: Decodable { let name: String?; let date: String? }
        let message: String
        let author: Author?
    }
    let sha: String
    let commit: Inner
    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
    var firstLine: String { commit.message.components(separatedBy: "\n").first ?? commit.message }
}

struct GHPull: Decodable, Identifiable {
    struct Head: Decodable { let ref: String }
    let number: Int
    let title: String
    let head: Head
    let html_url: String
    var id: Int { number }
}

struct GHContentItem: Decodable, Identifiable {
    let name: String
    let path: String
    let sha: String
    let type: String             // "file" | "dir"
    var id: String { path }
}

struct GHFile: Decodable {
    let content: String?
    let sha: String
    let path: String

    func decodedText() -> String? {
        guard let c = content,
              let data = Data(base64Encoded: c.replacingOccurrences(of: "\n", with: ""))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct GHPutResponse: Decodable {
    struct CommitRef: Decodable { let sha: String }
    struct ContentRef: Decodable { let sha: String }
    let commit: CommitRef
    let content: ContentRef?
}

enum GitHubAPI {
    static func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let token = Keychain.get(Keychain.githubPAT) else { throw APIError.noToken("GitHub") }
        guard let url = URL(string: "https://api.github.com\(path)") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("LexCockpit", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            // 409 (ref out of date) and 422 with a sha complaint = concurrent edit.
            if http.statusCode == 409 { throw APIError.conflict }
            if http.statusCode == 422 {
                let msg = String(data: data.prefix(400), encoding: .utf8) ?? ""
                if msg.contains("sha") { throw APIError.conflict }
                throw APIError.http(422, msg)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
            }
        }
        return data
    }

    static func escape(_ p: String) -> String {
        p.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    static func commits(repo: String, perPage: Int = 15) async throws -> [GHCommit] {
        try JSONDecoder().decode([GHCommit].self,
            from: try await request("/repos/\(repo)/commits?per_page=\(perPage)"))
    }

    static func pulls(repo: String) async throws -> [GHPull] {
        try JSONDecoder().decode([GHPull].self,
            from: try await request("/repos/\(repo)/pulls?state=open&per_page=20"))
    }

    static func listDir(repo: String, path: String) async throws -> [GHContentItem] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        return try JSONDecoder().decode([GHContentItem].self,
            from: try await request("/repos/\(repo)/contents/\(escape(clean))"))
    }

    static func file(repo: String, path: String) async throws -> GHFile {
        try JSONDecoder().decode(GHFile.self,
            from: try await request("/repos/\(repo)/contents/\(escape(path))"))
    }

    struct GHTreeItem: Decodable { let path: String; let type: String; let sha: String }
    private struct GHTree: Decodable { let tree: [GHTreeItem] }

    /// One request for the whole repo file list (vs. N directory calls).
    static func tree(repo: String) async throws -> [GHTreeItem] {
        let data = try await request("/repos/\(repo)/git/trees/HEAD?recursive=1")
        return try JSONDecoder().decode(GHTree.self, from: data).tree
    }

    /// Create (sha == nil) or update (sha != nil) a file. Throws `.conflict`
    /// when the given SHA no longer matches the file on GitHub.
    static func put(repo: String, path: String, message: String, text: String, sha: String?) async throws -> GHPutResponse {
        var payload: [String: Any] = [
            "message": message,
            "content": Data(text.utf8).base64EncodedString(),
        ]
        if let sha = sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GHPutResponse.self,
            from: try await request("/repos/\(repo)/contents/\(escape(path))", method: "PUT", body: body))
    }
}

// MARK: - Small helpers

func relativeTime(_ iso: String?) -> String {
    guard let iso = iso else { return "—" }
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return prettyDate(iso) }
    let rf = RelativeDateTimeFormatter()
    rf.unitsStyle = .abbreviated
    return rf.localizedString(for: date, relativeTo: Date())
}
