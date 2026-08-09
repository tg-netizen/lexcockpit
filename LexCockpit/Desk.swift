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
    /// What a click costs, in the row's own words ("open as a brief").
    /// Shown on hover — a worklist row that does not say what it does is
    /// a dashboard tile with extra steps.
    var hint: String = ""
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
    /// Words that describe what happened rather than what it happened to.
    /// "3 items circling 'adds'" is not a subject, and the first build of this
    /// screen offered exactly that as a story worth writing.
    nonisolated static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "new", "its", "his", "her",
        "will", "have", "has", "been", "more", "than", "what", "when", "where", "which",
        "while", "their", "there", "these", "those", "after", "into", "over", "amid",
        // verbs a headline reaches for, in the two forms a feed uses
        "adds", "says", "said", "sets", "puts", "takes", "makes", "calls", "urges",
        "warns", "plans", "seeks", "backs", "signs", "faces", "sees", "gets", "aims",
        "moves", "holds", "opens", "ends", "cuts", "hits", "wins", "keeps", "shows",
        "finds", "tells", "asks", "expects", "announces", "announced", "reports",
        "reported", "confirms", "confirmed", "launches", "launched", "passes", "passed",
        "adopts", "adopted", "unveils", "agrees", "agreed", "rejects", "rejected",
        "approves", "approved", "considers", "prepares", "eu",
        // German, which arrives from the Bundesregierung and ministry feeds
        "über", "der", "die", "das", "und", "von", "für", "sich", "dem", "den", "ein",
        "eine", "mit", "auf", "aus", "bei", "nach", "wird", "werden", "haben", "nicht",
        "auch", "noch", "aber", "oder", "zum", "zur", "des", "als", "ist", "sind"
    ]

    nonisolated static func keywords(_ it: ReviewQueueItem) -> Set<String> {
        let words = it.displayTitle.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stop.contains($0) && Int($0) == nil }
        return Set(words.prefix(6))
    }

    private static func distinctSources(_ items: [ReviewQueueItem]) -> Int {
        Set(items.compactMap { $0.source_name }.filter { !$0.isEmpty }).count
    }

    /// Cluster the waiting list by shared vocabulary.
    ///
    /// Two gates, and the second one is the point: a cluster needs `minSize`
    /// items **from at least `minSources` different outlets**. Counting items
    /// alone was wrong — the first build of this screen proposed "3 items
    /// circling 'adds'" carrying a `1 source` badge, which is one outlet
    /// repeating itself. That is the rewrite the news method forbids, offered
    /// under the label of a story.
    ///
    /// Clusters are also disjoint. Picking the best bucket and then removing
    /// its items means one story cannot fill the screen three times under
    /// three of its own words, which is what "sanctions" / "china" / "adds"
    /// were on 9 August — the same Chinese countermeasures article, listed
    /// three times.
    static func clusters(_ items: [ReviewQueueItem],
                         minSize: Int = 3,
                         minSources: Int = 2) -> [(key: String, items: [ReviewQueueItem])] {
        var pool = items
        var out: [(key: String, items: [ReviewQueueItem])] = []
        while out.count < 4 {
            guard let best = bestBucket(pool, minSize: minSize, minSources: minSources)
            else { break }
            out.append(best)
            let taken = Set(best.items.map { $0.id })
            pool = pool.filter { !taken.contains($0.id) }
        }
        return out
    }

    private static func bestBucket(_ items: [ReviewQueueItem],
                                   minSize: Int,
                                   minSources: Int) -> (key: String, items: [ReviewQueueItem])? {
        var buckets: [String: [ReviewQueueItem]] = [:]
        for it in items {
            for w in keywords(it) { buckets[w, default: []].append(it) }
        }
        /* Independent corroboration outranks volume: four items from two
           outlets are a weaker brief than three items from three. */
        let winner = buckets
            .filter { $0.value.count >= minSize && distinctSources($0.value) >= minSources }
            .max { a, b in
                let (sa, sb) = (distinctSources(a.value), distinctSources(b.value))
                if sa != sb { return sa < sb }
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                return a.key > b.key          // deterministic on a full tie
            }
        return winner.map { (key: $0.key, items: $0.value) }
    }

    static func rows(model: WorkspaceModel,
                     radarUnseen: Int,
                     radarAlarm: String?,
                     openQueue: @escaping () -> Void,
                     openEntry: @escaping (ContentEntry) -> Void,
                     seedDraft: @escaping (String, [ReviewQueueItem]) -> Void) -> [DeskRow] {
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
        /* The site promises daily EUR-Lex verification. When the data behind
           that promise stalls, the promise becomes the false claim — and this
           app is the only thing that reads both the promise and the data. */
        if let stale = radarAlarm {
            out.append(DeskRow(kind: .alarm, title: "The tracker has stopped being fed",
                               detail: stale, badge: "stale", action: nil))
        }

        // 2 · Opportunities — clusters that are ready to become a brief.
        //     The row opens the draft. Naming what a click costs is the
        //     difference between a worklist and a dashboard.
        for c in clusters(model.reviewQueue) {
            let sources = distinctSources(c.items)
            out.append(DeskRow(
                kind: .opportunity,
                title: "\(c.items.count) items circling “\(c.key)”",
                detail: c.items.prefix(2).map { $0.displayTitle }.joined(separator: " · "),
                badge: "\(sources) source\(sources == 1 ? "" : "s")",
                hint: "open as a brief",
                action: { seedDraft(c.key, c.items) }))
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
                               hint: "open the draft",
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
    ///
    /// `trackerFetched` is passed in rather than assumed: "the tracker is
    /// current" is only allowed on the QUIET line if something actually
    /// checked, which is the entire lesson of the empty waiting list.
    static func quiet(model: WorkspaceModel, trackerFetched: String? = nil) -> [String] {
        var q: [String] = []
        if let raw = trackerFetched, let when = TrackerFreshness.parseISO(raw) {
            q.append("tracker fetched \(LoadState<Int>.ago(when))")
        }
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
    @EnvironmentObject var store: CockpitStore
    var openQueue: () -> Void
    var openEntry: (ContentEntry) -> Void
    var seedDraft: (String, [ReviewQueueItem]) -> Void

    private var rows: [DeskRow] {
        DeskBuilder.rows(model: model, radarUnseen: radar.unseenCount,
                         radarAlarm: store.trackerFreshnessAlarm,
                         openQueue: openQueue, openEntry: openEntry,
                         seedDraft: seedDraft)
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
                Text(DeskBuilder.quiet(model: model, trackerFetched: store.trackerMeta?.lastFetched).joined(separator: " · "))
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
        Text(DeskBuilder.quiet(model: model, trackerFetched: store.trackerMeta?.lastFetched)
            .joined(separator: "  ·  "))
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
                if hovering, !row.hint.isEmpty, row.action != nil {
                    Text("→ " + row.hint)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(row.tint)
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
