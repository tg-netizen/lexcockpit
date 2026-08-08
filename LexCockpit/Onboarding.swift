import SwiftUI

// MARK: - Connection tests ("does this key actually work?")

/// One-tap per-service checks used by Settings + first-run onboarding.
/// Every test returns a short human verdict, never throws into the UI.
enum ConnectionTest {
    static func github() async -> String {
        guard Keychain.has(Keychain.githubPAT) else { return "✗ no token saved" }
        do {
            struct User: Decodable { let login: String }
            let data = try await GitHubAPI.request("/user")
            let user = try JSONDecoder().decode(User.self, from: data)
            return "✓ authenticated as \(user.login)"
        } catch { return "✗ \(short(error))" }
    }

    static func netlify(siteId: String?) async -> String {
        guard let token = Keychain.get(Keychain.netlifyPAT) else { return "✗ no token saved" }
        var req = URLRequest(url: URL(string: "https://api.netlify.com/api/v1/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return "✗ HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            struct User: Decodable { let email: String? }
            let user = try JSONDecoder().decode(User.self, from: data)
            var verdict = "✓ authenticated (\(user.email ?? "ok"))"
            if (siteId ?? "").isEmpty { verdict += " — netlify_site_id still empty in projects.json" }
            return verdict
        } catch { return "✗ \(short(error))" }
    }

    static func canva() async -> String {
        guard await CanvaAuth.shared.isConnected else { return "✗ not connected yet" }
        do {
            _ = try await CanvaAPI.listDesigns()
            return "✓ connected — designs reachable"
        } catch { return "✗ \(short(error))" }
    }

    static func plausible(host: String) async -> String {
        guard let key = Keychain.get(Keychain.plausibleKey) else { return "✗ no key saved" }
        var req = URLRequest(url: URL(string:
            "https://plausible.io/api/v1/stats/aggregate?site_id=\(host)&period=7d&metrics=visitors")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "✓ stats for \(host) reachable" : "✗ HTTP \(code)"
        } catch { return "✗ \(short(error))" }
    }

    static func mailerlite() async -> String {
        guard let key = Keychain.get(Keychain.mailerliteKey) else { return "✗ no key saved" }
        var req = URLRequest(url: URL(string: "https://connect.mailerlite.com/api/campaigns?limit=1")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "✓ account reachable" : "✗ HTTP \(code)"
        } catch { return "✗ \(short(error))" }
    }

    static func supabase() async -> String {
        guard Keychain.has(Keychain.supabaseAnonKey) else { return "✗ no anon key saved" }
        do {
            let items = try await SupabaseAPI.listReviewQueue()
            return "✓ review_queue reachable (\(items.count) waiting)"
        } catch { return "✗ \(short(error))" }
    }

    private static func short(_ error: Error) -> String {
        let s = error.localizedDescription
        return s.count > 90 ? String(s.prefix(87)) + "…" : s
    }
}

// MARK: - Skeleton loading (professional feel while feeds arrive)

struct SkeletonCard: View {
    var lines: Int = 2
    @State private var pulse = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.cardBorder)
                    .frame(width: 180, height: 12)
                ForEach(0..<lines, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.cardBorder.opacity(0.6))
                        .frame(maxWidth: i.isMultiple(of: 2) ? .infinity : 260)
                        .frame(height: 9)
                }
            }
            .opacity(pulse ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
        }
        .accessibilityLabel("Loading")
    }
}

struct SkeletonStack: View {
    var count: Int = 3
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in SkeletonCard() }
        }
    }
}
