import SwiftUI

// MARK: - Analytics (Plausible + MailerLite, keys in Keychain)

extension Keychain {
    static let plausibleKey = "plausible_api_key"
    static let mailerliteKey = "mailerlite_api_key"
}

struct PlausibleAggregate: Decodable {
    struct Results: Decodable {
        struct Metric: Decodable { let value: Double }
        let visitors: Metric?
        let pageviews: Metric?
        let bounce_rate: Metric?
    }
    let results: Results
}

struct PlausiblePage: Decodable, Identifiable {
    let page: String
    let visitors: Double?
    var id: String { page }
}

struct MLCampaign: Decodable, Identifiable {
    struct Stats: Decodable {
        let sent: Int?
        let opens_count: Int?
        let open_rate: RateBox?
        struct RateBox: Decodable { let float: Double? }
    }
    let id: String
    let name: String
    let stats: Stats?
}

@MainActor
final class AnalyticsModel: ObservableObject {
    @Published var visitors = "—"
    @Published var pageviews = "—"
    @Published var bounce = "—"
    @Published var topPages: [PlausiblePage] = []
    @Published var campaigns: [MLCampaign] = []
    @Published var plausibleError: String?
    @Published var mlError: String?
    @Published var loading = false

    func load(siteHost: String) async {
        loading = true
        defer { loading = false }
        await loadPlausible(siteHost: siteHost)
        await loadMailerLite()
    }

    private func loadPlausible(siteHost: String) async {
        guard let key = Keychain.get(Keychain.plausibleKey) else {
            plausibleError = "Add a Plausible API key in Settings to see traffic."
            return
        }
        plausibleError = nil
        func get(_ path: String) async throws -> Data {
            var req = URLRequest(url: URL(string: "https://plausible.io/api/v1\(path)")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                    String(data: data.prefix(160), encoding: .utf8) ?? "")
            }
            return data
        }
        do {
            let agg = try JSONDecoder().decode(PlausibleAggregate.self, from: try await get(
                "/stats/aggregate?site_id=\(siteHost)&period=30d&metrics=visitors,pageviews,bounce_rate"))
            visitors = "\(Int(agg.results.visitors?.value ?? 0))"
            pageviews = "\(Int(agg.results.pageviews?.value ?? 0))"
            bounce = "\(Int(agg.results.bounce_rate?.value ?? 0)) %"

            struct Breakdown: Decodable { let results: [PlausiblePage] }
            let pages = try JSONDecoder().decode(Breakdown.self, from: try await get(
                "/stats/breakdown?site_id=\(siteHost)&period=30d&property=event:page&limit=8&metrics=visitors"))
            topPages = pages.results
        } catch {
            plausibleError = error.localizedDescription
        }
    }

    private func loadMailerLite() async {
        guard let key = Keychain.get(Keychain.mailerliteKey) else {
            mlError = "Add a MailerLite API key in Settings to see newsletter stats."
            return
        }
        mlError = nil
        var req = URLRequest(url: URL(string:
            "https://connect.mailerlite.com/api/campaigns?filter[status]=sent&limit=5")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                mlError = "MailerLite HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            struct Envelope: Decodable { let data: [MLCampaign] }
            campaigns = (try JSONDecoder().decode(Envelope.self, from: data)).data
        } catch {
            mlError = error.localizedDescription
        }
    }
}

struct AnalyticsView: View {
    @EnvironmentObject var store: CockpitStore
    @StateObject private var model = AnalyticsModel()

    private var siteHost: String {
        (store.sites.first?.url ?? "https://lexdigestglobal.com")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        Page(title: "Analytics",
             subtitle: "Site traffic (Plausible, 30 days) and newsletter performance (MailerLite)") {
            if model.loading { ProgressView().controlSize(.small) }

            LazyVGrid(columns: grid(min: 160), spacing: 14) {
                StatTile(value: model.visitors, label: "Visitors · 30d")
                StatTile(value: model.pageviews, label: "Pageviews · 30d")
                StatTile(value: model.bounce, label: "Bounce rate", accent: .statusAmber)
            }
            if let err = model.plausibleError {
                Card { Label(err, systemImage: "info.circle").foregroundColor(.textSecondary) }
            }

            if !model.topPages.isEmpty {
                Text("Top pages")
                    .font(.system(size: 18, weight: .bold)).foregroundColor(.textPrimary)
                VStack(spacing: 8) {
                    ForEach(model.topPages) { page in
                        Card {
                            HStack {
                                Text(page.page).font(.system(.callout, design: .monospaced))
                                    .foregroundColor(.textPrimary).lineLimit(1)
                                Spacer()
                                Text("\(Int(page.visitors ?? 0)) visitors")
                                    .font(.caption).foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
            }

            Text("Recent newsletters")
                .font(.system(size: 18, weight: .bold)).foregroundColor(.textPrimary)
                .padding(.top, 8)
            if let err = model.mlError {
                Card { Label(err, systemImage: "info.circle").foregroundColor(.textSecondary) }
            }
            VStack(spacing: 8) {
                ForEach(model.campaigns) { c in
                    Card {
                        HStack {
                            Text(c.name).fontWeight(.medium).foregroundColor(.textPrimary).lineLimit(1)
                            Spacer()
                            if let sent = c.stats?.sent { Pill(text: "\(sent) sent") }
                            if let rate = c.stats?.open_rate?.float {
                                Pill(text: String(format: "%.0f %% open", rate * 100), color: .statusGreen)
                            }
                        }
                    }
                }
            }
        }
        .task { await model.load(siteHost: siteHost) }
    }
}
