import SwiftUI

/// The Desk — what today needs, in the order it needs it.
///
/// It replaces a wall of nine stat tiles. Tiles are a monitoring idiom and
/// this is not a monitoring app: the numbers on those tiles were almost
/// always the same, and they spent the most valuable space on screen saying
/// so. A number that does not change does not deserve a tile. It deserves a
/// word in a sentence at the bottom saying everything is fine.
///
/// Two sections and one rule:
///   · ATTENTION — generated, never curated. Each row states what it is and
///     what it would cost to act on it.
///   · QUIET — one line for everything that is in order. If that line is
///     long, the day is good.
///
/// Nothing here is decorative. A row exists because something is waiting,
/// stalled, or contradicting itself.
struct DeskRow: Identifiable {
    enum Kind { case alarm, opportunity, stalled, routine }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let badge: String
    var action: (() -> Void)?

    var tint: Color {
        switch kind {
        case .alarm:       return .statusRed
        case .opportunity: return .brandGold
        case .stalled:     return .statusAmber
        case .routine:     return .textSecondary
        }
    }
    var icon: String {
        switch kind {
        case .alarm:       return "exclamationmark.2"
        case .opportunity: return "sparkle"
        case .stalled:     return "clock.arrow.circlepath"
        case .routine:     return "circle"
        }
    }
}

@MainActor
enum DeskBuilder {
    /// Cluster the waiting list by shared vocabulary. Three or more items
    /// circling the same subject is the signal that a brief is available —
    /// and it is also the rule the news method requires, because a single
    /// source is a rewrite and three sources are a story.
    static func clusters(_ items: [ReviewQueueItem], minSize: Int = 3) -> [(key: String, items: [ReviewQueueItem])] {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "new",
                                 "eu", "über", "der", "die", "das", "und", "von", "für",
                                 "says", "after", "into", "over", "amid", "its", "his", "her"]
        var buckets: [String: [ReviewQueueItem]] = [:]
        for it in items {
            let words = it.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stop.contains($0) }
            /* Two keywords per item, not one: a single word buckets half the
               feed under "russia" and tells you nothing you did not know. */
            for w in Set(words.prefix(6)) { buckets[w, default: []].append(it) }
        }
        return buckets
            .filter { $0.value.count >= minSize }
            .sorted { $0.value.count > $1.value.count }
            .prefix(4)
            .map { (key: $0.key, items: $0.value) }
    }

    static func rows(model: WorkspaceModel,
                     radarUnseen: Int,
                     openQueue: @escaping () -> Void,
                     openEntry: @escaping (ContentEntry) -> Void) -> [DeskRow] {
        var out: [DeskRow] = []

        // 1 · Contradictions first. They mean a number on screen is wrong.
        if let clash = model.queueContradiction {
            out.append(DeskRow(kind: .alarm, title: "The queue and the pipeline disagree",
                               detail: clash, badge: "check policies", action: openQueue))
        }
        if let err = model.reviewQueueError {
            out.append(DeskRow(kind: .alarm, title: "Waiting list could not be read",
                               detail: err, badge: "failed", action: openQueue))
        }
        if let err = model.deploysError {
            out.append(DeskRow(kind: .alarm, title: "Deploys could not be read",
                               detail: err, badge: "failed", action: nil))
        }

        // 2 · Opportunities — clusters that are ready to become a brief.
        for c in clusters(model.reviewQueue) {
            let sources = Set(c.items.compactMap { $0.source_name }).count
            out.append(DeskRow(
                kind: .opportunity,
                title: "\(c.items.count) items circling “\(c.key)”",
                detail: c.items.prefix(2).map { $0.title }.joined(separator: " · "),
                badge: "\(sources) source\(sources == 1 ? "" : "s")",
                action: openQueue))
        }

        // 3 · Drafts that have stopped moving. A finished draft nobody
        //     published is the most expensive thing in the repository.
        let now = Date()
        for d in model.contentEntries where d.isDraft && d.scheduled.isEmpty && d.words > 400 {
            guard let day = ISO8601DateFormatter().date(from: d.date + "T00:00:00Z")
                    ?? DateFormatter.ymd.date(from: d.date) else { continue }
            let age = Int(now.timeIntervalSince(day) / 86400)
            guard age >= 7 else { continue }
            out.append(DeskRow(kind: .stalled,
                               title: "“\(d.title)” has been a draft for \(age) days",
                               detail: "\(d.words) words, ready to read",
                               badge: "stalled",
                               action: { openEntry(d) }))
        }

        if radarUnseen > 0 {
            out.append(DeskRow(kind: .opportunity,
                               title: "\(radarUnseen) tracked change\(radarUnseen == 1 ? "" : "s") unreviewed",
                               detail: "Regulatory movement the site recorded and nobody has looked at.",
                               badge: "radar", action: nil))
        }
        return out
    }

    /// The other half: everything that is fine, in one sentence.
    static func quiet(model: WorkspaceModel) -> [String] {
        var q: [String] = []
        if case .loaded(let rows, let at) = model.reviewQueueState, !rows.isEmpty {
            q.append("\(rows.count) in the waiting list, checked \(LoadState<Int>.ago(at))")
        }
        if case .loaded(let d, _) = model.deploysState, let last = d.first {
            q.append("last deploy \(last.state)")
        }
        let pub = model.contentEntries.filter { $0.status == "published" }.count
        if pub > 0 { q.append("\(pub) published") }
        if case .never = model.contentState { q.append("content not loaded yet") }
        return q
    }
}

extension DateFormatter {
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - The view

struct DeskView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var radar = RadarStore.shared
    var openQueue: () -> Void
    var openEntry: (ContentEntry) -> Void

    private var rows: [DeskRow] {
        DeskBuilder.rows(model: model, radarUnseen: radar.unseenCount,
                         openQueue: openQueue, openEntry: openEntry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rows.isEmpty {
                allClear
            } else {
                Text("Today")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundColor(.textSecondary)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider() }
                        DeskRowView(row: row)
                    }
                }
                .background(Color.bgCard)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                quietLine
            }
        }
    }

    private var allClear: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundColor(.stApplied)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing needs you").font(.system(size: 15, weight: .semibold))
                Text(DeskBuilder.quiet(model: model).joined(separator: " · "))
                    .font(.caption).foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var quietLine: some View {
        Text(DeskBuilder.quiet(model: model).joined(separator: "  ·  "))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.textSecondary)
            .padding(.top, 2)
    }
}

private struct DeskRowView: View {
    let row: DeskRow
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.icon)
                .foregroundColor(row.tint)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption).foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(row.badge)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundColor(row.tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay(Capsule().stroke(row.tint.opacity(0.5), lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(hovering && row.action != nil ? Color.cardBorder.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { row.action?() }
    }
}
