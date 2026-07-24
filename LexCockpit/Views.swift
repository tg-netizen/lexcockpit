import SwiftUI
import AppKit
import UniformTypeIdentifiers

// A shared scaffold: cream background, padding, optional error banner.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @EnvironmentObject var store: CockpitStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: title, subtitle: subtitle)
                if let err = store.errorMessage {
                    Card { Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.stBlocked) }
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.brandCream)
    }
}

func grid(min: CGFloat = 300) -> [GridItem] { [GridItem(.adaptive(minimum: min), spacing: 14)] }

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Dashboard",
             subtitle: store.lastFetched.isEmpty ? "Your operation at a glance"
                        : "Feeds updated \(prettyDate(store.lastFetched))") {
            LazyVGrid(columns: grid(min: 160), spacing: 14) {
                StatTile(value: "\(store.publishedCount)", label: "Published", accent: .stApplied)
                StatTile(value: "\(store.draftCount)", label: "In draft", accent: .brandNavy)
                StatTile(value: "\(store.inForceCount)", label: "Rules in force", accent: .stApplied)
                StatTile(value: "\(store.upcomingCount)", label: "Upcoming", accent: .stUpcoming)
                StatTile(value: "\(store.blockedCount)", label: "Blocked / in flux", accent: .stBlocked)
                StatTile(value: "\(store.negotiations.count)", label: "In trilogue", accent: .brandNavy)
            }

            Text("Next deadlines")
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundColor(.brandNavy)
                .padding(.top, 8)

            let upcoming = store.regulations
                .filter { $0.status == .upcoming && ($0.applicationDate ?? "") >= todayISO() }
                .sorted { ($0.applicationDate ?? "") < ($1.applicationDate ?? "") }
                .prefix(6)

            if upcoming.isEmpty {
                Card { Text("No upcoming deadlines loaded.").foregroundColor(.secondary) }
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(upcoming)) { r in
                        Card {
                            HStack {
                                Text(prettyDate(r.applicationDate))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Text(r.name).fontWeight(.semibold)
                                Spacer()
                                pill(for: r.status)
                            }
                        }
                    }
                }
            }
        }
    }
}

// (The editorial-pipeline grid moved into the project workspace —
//  see OverviewTabView in Workspace.swift.)

// MARK: - Tracker

struct TrackerView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Regulation Tracker",
             subtitle: "Status, dates and transition phases · from EUR-Lex") {
            LazyVGrid(columns: grid(min: 360), spacing: 14) {
                ForEach(store.regulations) { r in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(r.name)
                                    .font(.system(.title3, design: .serif).weight(.semibold))
                                    .foregroundColor(.brandNavy)
                                Spacer()
                                pill(for: r.status)
                            }
                            if let area = r.area { Text(area).font(.caption).foregroundColor(.secondary) }
                            if let note = r.statusNote, !note.isEmpty {
                                Text(note).font(.callout).foregroundColor(.stUpcoming)
                            }
                            if let phases = r.transitionPhases, !phases.isEmpty {
                                Divider().padding(.vertical, 2)
                                ForEach(phases) { ph in
                                    HStack(alignment: .top) {
                                        Text(prettyDate(ph.date))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 96, alignment: .leading)
                                        Text(ph.label).font(.caption)
                                    }
                                }
                            }
                            if let u = r.sourceUrl, let url = URL(string: u) {
                                Link("Primary source →", destination: url).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pipeline

struct PipelineView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Commission Pipeline",
             subtitle: "What the Commission plans to propose") {
            LazyVGrid(columns: grid(min: 340), spacing: 14) {
                ForEach(store.pipeline) { it in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let dg = it.responsible_dg { Pill(text: dg, color: .brandNavy) }
                                if let q = it.planned_quarter { Pill(text: q, color: .brandGold.opacity(0.9)) }
                                if let p = it.priority { Pill(text: p, color: .stUpcoming) }
                                Spacer()
                            }
                            Text(it.title)
                                .font(.system(.title3, design: .serif).weight(.semibold))
                                .foregroundColor(.brandNavy)
                            if let b = it.brief { Text(b).font(.callout).foregroundColor(.secondary) }
                            if let u = it.have_your_say_url, let url = URL(string: u) {
                                Link("Consultation open →", destination: url).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Trilogue

struct TrilogueView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Trilogue Tracker",
             subtitle: "Files in interinstitutional negotiation") {
            LazyVGrid(columns: grid(min: 360), spacing: 14) {
                ForEach(store.negotiations) { n in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let s = n.current_stage { Pill(text: s.replacingOccurrences(of: "-", with: " "), color: .brandNavy) }
                                Spacer()
                                if let lu = n.last_update { Text("updated \(prettyDate(lu))").font(.caption).foregroundColor(.secondary) }
                            }
                            Text(n.title)
                                .font(.system(.title3, design: .serif).weight(.semibold))
                                .foregroundColor(.brandNavy)
                            HStack(spacing: 10) {
                                if let p = n.council_presidency { Text("Presidency: \(p)").font(.caption).foregroundColor(.secondary) }
                                if let s = n.sessions_held { Text("· \(s) session(s)").font(.caption).foregroundColor(.secondary) }
                            }
                            if let note = n.note { Text(note).font(.callout) }
                            if let pts = n.sticking_points, !pts.isEmpty {
                                Text("Sticking points").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                ForEach(pts, id: \.self) { pt in
                                    Text("• \(pt)").font(.caption)
                                }
                            }
                            if let u = n.oeil_url, let url = URL(string: u) {
                                Link("OEIL file →", destination: url).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Enforcement

struct EnforcementView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Enforcement",
             subtitle: "Fines and decisions under GDPR, DMA and DSA") {
            VStack(spacing: 12) {
                ForEach(store.cases.sorted { ($0.date ?? "") > ($1.date ?? "") }) { c in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(c.entity ?? "—")
                                    .font(.system(.title3, design: .serif).weight(.semibold))
                                    .foregroundColor(.brandNavy)
                                Spacer()
                                Text(formatEuro(c.amount_eur))
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundColor(.stBlocked)
                            }
                            HStack(spacing: 8) {
                                if let r = c.regulation { Pill(text: r, color: .brandNavy) }
                                if let j = c.jurisdiction { Pill(text: j, color: .brandGold.opacity(0.9)) }
                                if let a = c.authority { Text(a).font(.caption).foregroundColor(.secondary) }
                                Spacer()
                                Text(prettyDate(c.date)).font(.caption).foregroundColor(.secondary)
                            }
                            if let conduct = c.conduct { Text(conduct).font(.callout).foregroundColor(.secondary) }
                            if let u = c.source_url, let url = URL(string: u) {
                                Link("Source →", destination: url).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}
