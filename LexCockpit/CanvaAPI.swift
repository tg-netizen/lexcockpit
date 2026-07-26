import Foundation
import CryptoKit
import Network
import AppKit

// MARK: - Errors

enum CanvaError: LocalizedError {
    case notConfigured
    case notConnected
    case reconnectNeeded
    case oauth(String)
    case http(Int, String)
    case exportFailed(String)
    case exportTimeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:   return "Add your Canva Client ID + Secret in Settings first."
        case .notConnected:    return "Not connected to Canva — use “Connect Canva” in Settings."
        case .reconnectNeeded: return "Canva session expired — reconnect in Settings."
        case .oauth(let m):    return "Canva sign-in failed: \(m)"
        case .http(let c, let m): return "Canva API HTTP \(c): \(m)"
        case .exportFailed(let m): return "Canva export failed: \(m)"
        case .exportTimeout:   return "Canva export timed out."
        }
    }
}

// MARK: - PKCE (RFC 7636, S256)

enum PKCE {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

// MARK: - One-shot loopback listener (Network framework)

/// Listens once on 127.0.0.1:{port} for the OAuth redirect, answers with a
/// tiny "you can close this window" page, and shuts down. State-checked.
enum OAuthLoopback {
    static func waitForCallback(port: UInt16, expectedState: String,
                                timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let done = LockedFlag()
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                               port: NWEndpoint.Port(rawValue: port)!)
            guard let listener = try? NWListener(using: params) else {
                cont.resume(throwing: CanvaError.oauth("port \(port) is busy"))
                return
            }

            func finish(_ result: Result<String, Error>) {
                guard done.trySet() else { return }
                listener.cancel()
                switch result {
                case .success(let code): cont.resume(returning: code)
                case .failure(let err):  cont.resume(throwing: err)
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let query = Self.queryItems(fromRequestLine: request)
                    let ok = query["state"] == expectedState && query["code"] != nil
                    let bodyText = ok
                        ? "<h2 style='font-family:sans-serif'>LexCockpit is connected to Canva ✓</h2><p style='font-family:sans-serif'>You can close this window.</p>"
                        : "<h2 style='font-family:sans-serif'>Sign-in failed</h2><p style='font-family:sans-serif'>Please try again from LexCockpit.</p>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<!doctype html><html><body>\(bodyText)</body></html>"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        if ok, let code = query["code"] {
                            finish(.success(code))
                        } else if let err = query["error"] {
                            finish(.failure(CanvaError.oauth(err)))
                        } else if query["state"] != nil {
                            finish(.failure(CanvaError.oauth("state mismatch")))
                        }
                        // Non-callback request (favicon etc.): keep listening.
                    })
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    finish(.failure(CanvaError.oauth(err.localizedDescription)))
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(CanvaError.oauth("timed out waiting for the browser callback")))
            }
        }
    }

    /// Parse "GET /callback?a=b&c=d HTTP/1.1" → [a:b, c:d]
    static func queryItems(fromRequestLine request: String) -> [String: String] {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET "),
              let pathPart = line.components(separatedBy: " ").dropFirst().first,
              let qIndex = pathPart.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in pathPart[pathPart.index(after: qIndex)...].components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return out
    }

    final class LockedFlag {
        private let lock = NSLock()
        private var value = false
        func trySet() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }
}

// MARK: - Keychain accounts

extension Keychain {
    static let canvaClientID = "canva_client_id"
    static let canvaClientSecret = "canva_client_secret"
    static let canvaAccessToken = "canva_access_token"
    static let canvaRefreshToken = "canva_refresh_token"
}

// MARK: - Connection state (Settings UI)

@MainActor
final class CanvaAuth: ObservableObject {
    static let shared = CanvaAuth()

    @Published var connecting = false
    @Published var needsReconnect = false
    @Published var displayName: String? = UserDefaults.standard.string(forKey: "canvaDisplayName")
    @Published var lastError: String?
    /// Set when Canva rejected our scope list — Settings shows the exact
    /// scopes to enable plus a copy button.
    @Published var invalidScope = false

    var isConfigured: Bool { Keychain.has(Keychain.canvaClientID) && Keychain.has(Keychain.canvaClientSecret) }
    var isConnected: Bool { Keychain.has(Keychain.canvaRefreshToken) }

    static let redirectURI = "http://127.0.0.1:8976/callback"
    /// SINGLE source of truth — must match EXACTLY what is enabled under
    /// developer.canva.com → LexCockpit → Scopes. Requesting anything the
    /// integration hasn't enabled makes Canva reject with invalid_scope.
    static let canvaScopes = ["asset:read", "asset:write",
                              "design:content:read", "design:content:write",
                              "design:meta:read"]

    /// Strict RFC 3986 unreserved-only encoding: colons → %3A, spaces → %20
    /// (never '+').
    nonisolated static func strictEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Testable authorize-URL builder (regression-tested in --selftest).
    nonisolated static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        let scope = canvaScopes.map(strictEncode).joined(separator: "%20")
        let query = [
            "code_challenge=\(strictEncode(challenge))",
            "code_challenge_method=S256",
            "scope=\(scope)",
            "response_type=code",
            "client_id=\(strictEncode(clientID))",
            "state=\(strictEncode(state))",
            "redirect_uri=\(strictEncode(redirectURI))",
        ].joined(separator: "&")
        return URL(string: "https://www.canva.com/api/oauth/authorize?" + query)!
    }

    func connect() async {
        guard let clientID = Keychain.get(Keychain.canvaClientID),
              Keychain.has(Keychain.canvaClientSecret) else {
            lastError = CanvaError.notConfigured.localizedDescription
            return
        }
        connecting = true
        lastError = nil
        defer { connecting = false }

        invalidScope = false
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        let url = Self.authorizeURL(clientID: clientID,
                                    challenge: PKCE.challenge(for: verifier),
                                    state: state)
        #if DEBUG
        print("[canva] authorize: " + url.absoluteString
            .replacingOccurrences(of: Self.strictEncode(clientID), with: "‹client_id›"))
        #endif

        do {
            async let callback = OAuthLoopback.waitForCallback(port: 8976, expectedState: state, timeout: 180)
            NSWorkspace.shared.open(url)                       // system browser, never a webview
            let code = try await callback
            let tokens = try await CanvaAPI.exchangeCode(code, verifier: verifier)
            Keychain.set(Keychain.canvaAccessToken, tokens.access)
            Keychain.set(Keychain.canvaRefreshToken, tokens.refresh)
            needsReconnect = false
            let name = (try? await CanvaAPI.profileName()) ?? "Canva account"
            displayName = name
            UserDefaults.standard.set(name, forKey: "canvaDisplayName")
        } catch {
            if case CanvaError.oauth(let msg) = error, msg.contains("invalid_scope") {
                invalidScope = true
                lastError = "Canva rejected the requested scopes. Enable EXACTLY these under developer.canva.com → LexCockpit → Scopes, then retry:\n"
                    + Self.canvaScopes.joined(separator: "  ·  ")
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    static var scopeListForCopy: String { canvaScopes.joined(separator: " ") }

    func disconnect() {
        Keychain.delete(Keychain.canvaAccessToken)
        Keychain.delete(Keychain.canvaRefreshToken)
        UserDefaults.standard.removeObject(forKey: "canvaDisplayName")
        displayName = nil
        needsReconnect = false
    }

    func flagReconnect() {
        needsReconnect = true
    }
}

// MARK: - REST client

enum CanvaAPI {
    struct Tokens { let access: String; let refresh: String }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
    }

    static func exchangeCode(_ code: String, verifier: String) async throws -> Tokens {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": CanvaAuth.redirectURI,
        ])
    }

    static func refreshTokens() async throws -> Tokens {
        guard let refresh = Keychain.get(Keychain.canvaRefreshToken) else { throw CanvaError.notConnected }
        return try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        guard let id = Keychain.get(Keychain.canvaClientID),
              let secret = Keychain.get(Keychain.canvaClientSecret) else { throw CanvaError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.canva.com/rest/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(id):\(secret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.httpBody = form.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw CanvaError.oauth("token endpoint HTTP \(code): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(access: tokens.access_token, refresh: tokens.refresh_token)
    }

    /// Bearer request with one silent refresh on 401 (rotating refresh token
    /// is re-stored). A failed refresh flags the reconnect state.
    static func authorized(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        guard let access = Keychain.get(Keychain.canvaAccessToken) else { throw CanvaError.notConnected }
        do {
            return try await raw(path, method: method, json: json, bearer: access)
        } catch CanvaError.http(401, _) {
            do {
                let fresh = try await refreshTokens()
                Keychain.set(Keychain.canvaAccessToken, fresh.access)
                Keychain.set(Keychain.canvaRefreshToken, fresh.refresh)
                return try await raw(path, method: method, json: json, bearer: fresh.access)
            } catch {
                await CanvaAuth.shared.flagReconnect()
                throw CanvaError.reconnectNeeded
            }
        }
    }

    private static func raw(_ path: String, method: String, json: [String: Any]?, bearer: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.canva.com\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let json = json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CanvaError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Typed calls

    struct Design { let id: String; let editURL: String }

    private struct DesignEnvelope: Decodable {
        struct Inner: Decodable {
            struct URLs: Decodable { let edit_url: String }
            let id: String
            let urls: URLs
        }
        let design: Inner
    }

    static func createDesign(width: Int, height: Int, title: String) async throws -> Design {
        let body: [String: Any] = [
            "design_type": ["type": "custom", "width": width, "height": height],
            "title": title,
        ]
        let data = try await authorized("/rest/v1/designs", method: "POST", json: body)
        let env = try JSONDecoder().decode(DesignEnvelope.self, from: data)
        return Design(id: env.design.id, editURL: env.design.urls.edit_url)
    }

    static func design(id: String) async throws -> Design {
        let data = try await authorized("/rest/v1/designs/\(id)")
        let env = try JSONDecoder().decode(DesignEnvelope.self, from: data)
        return Design(id: env.design.id, editURL: env.design.urls.edit_url)
    }

    private struct ExportEnvelope: Decodable {
        struct Job: Decodable {
            struct Result: Decodable { let urls: [String]? }  // some payloads nest urls
            let id: String
            let status: String
            let urls: [String]?
        }
        let job: Job
    }

    static func startExport(designID: String) async throws -> String {
        let body: [String: Any] = ["design_id": designID, "format": ["type": "png"]]
        let data = try await authorized("/rest/v1/exports", method: "POST", json: body)
        return try JSONDecoder().decode(ExportEnvelope.self, from: data).job.id
    }

    /// Polls every 2 s (≤ 60 s). Cancellable via task cancellation.
    static func waitForExport(jobID: String) async throws -> URL {
        for _ in 0..<30 {
            try Task.checkCancellation()
            let data = try await authorized("/rest/v1/exports/\(jobID)")
            let job = try JSONDecoder().decode(ExportEnvelope.self, from: data).job
            switch job.status {
            case "success":
                guard let urlStr = job.urls?.first, let url = URL(string: urlStr) else {
                    throw CanvaError.exportFailed("no export URL in response")
                }
                return url
            case "failed":
                throw CanvaError.exportFailed("job reported failure")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw CanvaError.exportTimeout
    }

    static func download(_ url: URL) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CanvaError.http(http.statusCode, "export download")
        }
        return data
    }

    private struct ProfileEnvelope: Decodable {
        struct Profile: Decodable { let display_name: String? }
        let profile: Profile
    }

    static func profileName() async throws -> String {
        let data = try await authorized("/rest/v1/users/me/profile")
        return (try JSONDecoder().decode(ProfileEnvelope.self, from: data)).profile.display_name ?? "Canva account"
    }
}
