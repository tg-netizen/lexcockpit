import SwiftUI
import AppKit
import UniformTypeIdentifiers

// A shared scaffold: light page background, padding, optional projects-file error.
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
                    Card { Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.statusRed) }
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgPage)
    }
}

func grid(min: CGFloat = 300) -> [GridItem] { [GridItem(.adaptive(minimum: min), spacing: 14)] }

/// Inline per-feed state: error card when failed, helpful copy when empty.
struct FeedStateView: View {
    @EnvironmentObject var store: CockpitStore
    let kind: FeedKind
    let emptyText: String
    let isEmpty: Bool

    var body: some View {
        if let staleDate = store.feedStale[kind] {
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash").foregroundColor(.statusAmber)
                    Text("Offline — data from \(relativeTime(ISO8601DateFormatter().string(from: staleDate)))")
                        .font(.caption).foregroundColor(.statusAmber)
                    Spacer()
                }
            }
        } else if let failure = store.feedErrors[kind] {
            FeedErrorCard(title: "\(kind.title) feed", failure: failure)
        } else if isEmpty && store.feedLoaded.contains(kind) {
            Card { Text(emptyText).foregroundColor(.textSecondary) }
        } else if isEmpty {
            SkeletonStack(count: 3)
        }
    }
}

// (The old feeds dashboard became the Project Hub — see Hub.swift.)

// (The editorial-pipeline grid lives in the project workspace —
//  see OverviewTabView in Workspace.swift.)

// MARK: - Tracker

struct TrackerView: View {
    @EnvironmentObject var store: CockpitStore
    var body: some View {
        Page(title: "Regulation Tracker",
             subtitle: "Status, dates and transition phases · from EUR-Lex") {
            FeedStateView(kind: .tracker,
                          emptyText: "The tracker feed loaded but contains no regulations.",
                          isEmpty: store.regulations.isEmpty)
            LazyVGrid(columns: grid(min: 360), spacing: 14) {
                ForEach(store.regulations) { r in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(r.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                pill(for: r.status)
                            }
                            if let area = r.area { Text(area).font(.caption).foregroundColor(.textSecondary) }
                            if let note = r.statusNote, !note.isEmpty {
                                Text(note).font(.callout).foregroundColor(.statusAmber)
                            }
                            if let phases = r.transitionPhases, !phases.isEmpty {
                                Divider().padding(.vertical, 2)
                                ForEach(phases) { ph in
                                    HStack(alignment: .top) {
                                        Text(prettyDate(ph.date))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.textSecondary)
                                            .frame(width: 96, alignment: .leading)
                                        Text(ph.label).font(.caption).foregroundColor(.textPrimary)
                                    }
                                }
                            }
                            if let u = r.sourceUrl, let url = URL(string: u) {
                                Link("Primary source →", destination: url)
                                    .font(.caption).foregroundColor(.accentNavy)
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
            FeedStateView(kind: .pipeline,
                          emptyText: "The pipeline feed loaded but lists no planned files.",
                          isEmpty: store.pipeline.isEmpty)
            LazyVGrid(columns: grid(min: 340), spacing: 14) {
                ForEach(store.pipeline) { it in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let dg = it.responsible_dg { Pill(text: dg) }
                                if let q = it.planned_quarter { Pill(text: q, color: .brandGold) }
                                if let p = it.priority { Pill(text: p, color: .statusAmber) }
                                Spacer()
                            }
                            Text(it.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                            if let b = it.brief { Text(b).font(.callout).foregroundColor(.textSecondary) }
                            if let u = it.have_your_say_url, let url = URL(string: u) {
                                Link("Consultation open →", destination: url)
                                    .font(.caption).foregroundColor(.accentNavy)
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
            FeedStateView(kind: .trilogue,
                          emptyText: "The trilogue feed loaded but lists no active negotiations.",
                          isEmpty: store.negotiations.isEmpty)
            LazyVGrid(columns: grid(min: 360), spacing: 14) {
                ForEach(store.negotiations) { n in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let s = n.current_stage { Pill(text: s.replacingOccurrences(of: "-", with: " ")) }
                                Spacer()
                                if let lu = n.last_update {
                                    Text("updated \(relativeTime(lu))")
                                        .font(.caption).foregroundColor(.textSecondary)
                                        .help(prettyDate(lu))
                                }
                            }
                            Text(n.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                            HStack(spacing: 10) {
                                if let p = n.council_presidency { Text("Presidency: \(p)").font(.caption).foregroundColor(.textSecondary) }
                                if let s = n.sessions_held { Text("· \(s) session(s)").font(.caption).foregroundColor(.textSecondary) }
                            }
                            if let note = n.note { Text(note).font(.callout).foregroundColor(.textPrimary) }
                            if let pts = n.sticking_points, !pts.isEmpty {
                                Text("Sticking points").font(.caption.weight(.semibold)).foregroundColor(.textSecondary)
                                ForEach(pts, id: \.self) { pt in
                                    Text("• \(pt)").font(.caption).foregroundColor(.textPrimary)
                                }
                            }
                            if let u = n.oeil_url, let url = URL(string: u) {
                                Link("OEIL file →", destination: url)
                                    .font(.caption).foregroundColor(.accentNavy)
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
            FeedStateView(kind: .enforcement,
                          emptyText: "The enforcement feed loaded but lists no cases.",
                          isEmpty: store.cases.isEmpty)
            VStack(spacing: 12) {
                ForEach(store.cases.sorted { ($0.date ?? "") > ($1.date ?? "") }) { c in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(c.entity ?? "—")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                Text(formatEuro(c.amount_eur))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(.statusRed)
                            }
                            HStack(spacing: 8) {
                                if let r = c.regulation { Pill(text: r) }
                                if let j = c.jurisdiction { Pill(text: j, color: .brandGold) }
                                if let a = c.authority { Text(a).font(.caption).foregroundColor(.textSecondary) }
                                Spacer()
                                Text(prettyDate(c.date)).font(.caption).foregroundColor(.textSecondary)
                            }
                            if let conduct = c.conduct { Text(conduct).font(.callout).foregroundColor(.textSecondary) }
                            if let u = c.source_url, let url = URL(string: u) {
                                Link("Source →", destination: url)
                                    .font(.caption).foregroundColor(.accentNavy)
                            }
                        }
                    }
                }
            }
        }
    }
}
