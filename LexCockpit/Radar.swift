import SwiftUI
import AppKit

// MARK: - EUR-Lex Radar
//
// The WEBSITE already verifies against EUR-Lex daily (build-eurlex.js +
// tracker-changelog.js) — the app consumes those feeds and adds the missing
// piece: "what changed since I last looked", deadline lookahead, and a
// menubar badge. No duplicate EUR-Lex polling.

struct ChangelogEntry: Decodable, Identifiable {
    let date: String          // yyyy-MM-dd (when the change was detected)
    let id: String            // regulation id
    let name: String?
    let field: String         // which field changed, or "(new)" / "(removed)"
    let from: String?
    let to: String?

    var uid: String { date + "|" + id + "|" + field + "|" + (to ?? "") }
}

extension ChangelogEntry {
    var headline: String {
        let reg = name ?? id
        switch field {
        case "(new)":     return "\(reg) — added to the tracker"
        case "(removed)": return "\(reg) — removed from the tracker"
        default:          return "\(reg) — \(field) changed"
        }
    }
    var detail: String {
        guard field != "(new)", field != "(removed)" else { return "" }
        return "\(from ?? "—")  →  \(to ?? "—")"
    }
}

@MainActor
final class RadarStore: ObservableObject {
    static let shared = RadarStore()

    @Published var entries: [ChangelogEntry] = []
    @Published var error: String?
    @Published var loaded = false
    /// Newest entry date the user has acknowledged (UserDefaults — not secret).
    @Published var lastSeen: String = UserDefaults.standard.string(forKey: "radarLastSeen") ?? ""

    var unseen: [ChangelogEntry] { entries.filter { $0.date > lastSeen } }
    var unseenCount: Int { unseen.count }

    func load(base: String) async {
        guard let url = URL(string: base + "tracker-changelog.json") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                error = "changelog: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            entries = (try JSONDecoder().decode([ChangelogEntry].self, from: data))
                .sorted { $0.date > $1.date }
            error = nil
            loaded = true
            updateDockBadge()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markAllSeen() {
        let newest = entries.map(\.date).max() ?? todayISO()
        lastSeen = newest
        UserDefaults.standard.set(newest, forKey: "radarLastSeen")
        updateDockBadge()
    }

    func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unseenCount > 0 ? "\(unseenCount)" : ""
    }
}

// MARK: - Radar view

struct RadarView: View {
    @EnvironmentObject var store: CockpitStore
    @ObservedObject var radar = RadarStore.shared
    @State private var showBriefBuilder = false

    /// Deadlines within the next 30 days, from the tracker feed.
    private var upcomingDeadlines: [(date: String, label: String, reg: String)] {
        let today = todayISO()
        let horizon = isoDate(daysFromNow: 30)
        var out: [(String, String, String)] = []
        for reg in store.regulations {
            if let ad = reg.applicationDate, ad >= today, ad <= horizon {
                out.append((ad, "Application date", reg.name))
            }
            for phase in reg.transitionPhases ?? [] where phase.date >= today && phase.date <= horizon {
                out.append((phase.date, phase.label, reg.name))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        Page(title: "EUR-Lex Radar",
             subtitle: "What changed in your tracked regulations — powered by the site's daily EUR-Lex verification") {

            HStack {
                if radar.unseenCount > 0 {
                    Pill(text: "\(radar.unseenCount) new", color: .statusAmber)
                    Button("Mark all as seen") { radar.markAllSeen() }
                } else if radar.loaded {
                    Label("All caught up", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundColor(.statusGreen)
                }
                Spacer()
                Button {
                    showBriefBuilder = true
                } label: { Label("Draft weekly brief", systemImage: "envelope.badge") }
            }

            if let err = radar.error {
                Card { Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.statusRed) }
            }

            if radar.loaded && radar.entries.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No changes recorded yet").fontWeight(.semibold)
                        Text("The site's tracker-changelog starts filling up as soon as a tracked regulation changes on EUR-Lex. From then on, every change lands here.")
                            .font(.callout).foregroundColor(.textSecondary)
                    }
                }
            }

            if !radar.entries.isEmpty {
                Text("Changes")
                    .font(.system(size: 18, weight: .bold)).foregroundColor(.textPrimary)
                VStack(spacing: 8) {
                    ForEach(radar.entries.prefix(40), id: \.uid) { entry in
                        Card {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(entry.date > radar.lastSeen ? Color.statusAmber : Color.cardBorder)
                                    .frame(width: 8, height: 8).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.headline).fontWeight(.medium).foregroundColor(.textPrimary)
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.textSecondary)
                                    }
                                }
                                Spacer()
                                Text(prettyDate(entry.date)).font(.caption).foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
            }

            Text("Deadlines · next 30 days")
                .font(.system(size: 18, weight: .bold)).foregroundColor(.textPrimary)
                .padding(.top, 8)
            if upcomingDeadlines.isEmpty {
                Card { Text("No deadlines in the next 30 days.").foregroundColor(.textSecondary) }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(upcomingDeadlines.enumerated()), id: \.offset) { _, d in
                        Card {
                            HStack {
                                Text(prettyDate(d.date))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.statusAmber)
                                    .frame(width: 110, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.reg).fontWeight(.semibold).foregroundColor(.textPrimary)
                                    Text(d.label).font(.caption).foregroundColor(.textSecondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .task { await radar.load(base: store.feedBase) }
        .sheet(isPresented: $showBriefBuilder) { WeeklyBriefBuilder() }
    }
}

func isoDate(daysFromNow: Int) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date().addingTimeInterval(TimeInterval(daysFromNow) * 86400))
}

// MARK: - Weekly brief builder

/// Assembles a Wochenbrief draft from the last 7 days of tracked changes,
/// fresh articles and near-term deadlines. Output: copy as markdown/HTML,
/// open as a new draft article, or push a MailerLite draft (API key set).
struct WeeklyBriefBuilder: View {
    @EnvironmentObject var store: CockpitStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var radar = RadarStore.shared
    @State private var draft = ""
    @State private var status: String?
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Weekly brief draft").font(.system(size: 15, weight: .semibold))
                Text("· assembled from the last 7 days").font(.caption).foregroundColor(.textSecondary)
                Spacer()
                if let s = status { Text(s).font(.caption).foregroundColor(.textSecondary) }
                Button("Copy markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft, forType: .string)
                    status = "Copied ✓"
                }
                Button(sending ? "Sending…" : "MailerLite draft") { Task { await pushMailerLite() } }
                    .disabled(sending || !Keychain.has("mailerlite_api_key"))
                    .help(Keychain.has("mailerlite_api_key")
                          ? "Create a draft campaign in MailerLite"
                          : "Add a MailerLite API key in Settings first")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .padding(6)
        }
        .frame(width: 720, height: 540)
        .onAppear { draft = Self.compose(store: store, radar: radar) }
    }

    static func compose(store: CockpitStore, radar: RadarStore) -> String {
        let weekAgo = isoDate(daysFromNow: -7)
        var out = "# Weekly brief — \(prettyDate(todayISO()))\n\n"

        let changes = radar.entries.filter { $0.date >= weekAgo }
        out += "## What changed this week\n\n"
        if changes.isEmpty {
            out += "_No tracked regulation changed this week._\n\n"
        } else {
            for c in changes {
                out += "- **\(c.headline)**"
                if !c.detail.isEmpty { out += " — \(c.detail)" }
                out += "\n"
            }
            out += "\n"
        }

        if let site = store.sites.first {
            let fresh = WorkspaceModel.shared(for: site).contentEntries
                .filter { $0.date >= weekAgo && $0.status == "published" }
            if !fresh.isEmpty {
                out += "## New on the site\n\n"
                for a in fresh {
                    let slug = a.name.replacingOccurrences(of: ".md", with: "")
                    out += "- [\(a.title)](\(site.url ?? "")/articles/\(slug).html)\n"
                }
                out += "\n"
            }
        }

        let horizon = isoDate(daysFromNow: 14)
        let today = todayISO()
        var deadlines: [(String, String)] = []
        for reg in store.regulations {
            if let ad = reg.applicationDate, ad >= today, ad <= horizon {
                deadlines.append((ad, "\(reg.name): application date"))
            }
            for p in reg.transitionPhases ?? [] where p.date >= today && p.date <= horizon {
                deadlines.append((p.date, "\(reg.name): \(p.label)"))
            }
        }
        out += "## Deadlines · next 14 days\n\n"
        if deadlines.isEmpty { out += "_None._\n" }
        else {
            for d in deadlines.sorted(by: { $0.0 < $1.0 }) {
                out += "- \(prettyDate(d.0)) — \(d.1)\n"
            }
        }
        return out
    }

    private func pushMailerLite() async {
        guard let key = Keychain.get("mailerlite_api_key") else { return }
        sending = true
        defer { sending = false }
        var req = URLRequest(url: URL(string: "https://connect.mailerlite.com/api/campaigns")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let html = draft
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let payload: [String: Any] = [
            "name": "Weekly brief \(todayISO()) (LexCockpit draft)",
            "type": "regular",
            "emails": [[
                "subject": "Weekly brief — \(prettyDate(todayISO()))",
                "from_name": "LexDigestGlobal",
                "from": "t.g@lexdigestglobal.com",
                "content": "<html><body style=\"font-family:Georgia,serif\">\(html)</body></html>",
            ]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            status = (200..<300).contains(code)
                ? "MailerLite draft created ✓"
                : "MailerLite HTTP \(code): \(String(data: data.prefix(160), encoding: .utf8) ?? "")"
        } catch {
            status = error.localizedDescription
        }
    }
}
