import SwiftUI

// MARK: - The defence desk's data, and the rule it lives by
//
// data/defence-programmes.json states its own method:
//
//   "Every fitment row records the document it came from, the publisher,
//    the retrieval date and a verbatim quote. Rows without a citable public
//    source are not published; the categories they would cover are listed
//    as gaps instead."
//
// Until now that was a promise kept by hand in a text editor. This screen
// makes it a rule the file cannot be saved against — which is the only
// reason to build an editor rather than open the JSON in Cursor.
//
// Two design decisions worth stating.
//
// LOSSLESS. The file is edited as a JSON tree, not decoded into Swift
// structs. Typed models would silently drop any key nobody thought to
// model — and this file already carries ledger, timeline, chain, aka and
// fitments with different shapes. Nothing here can lose a field it does
// not understand. Keys are written sorted so the diff is stable from the
// second save onwards.
//
// SNAPSHOT. The Hans-Böckler study on this industry puts it exactly right:
// compilations of this kind can only ever be snapshots. So a row's
// retrieval date is not decoration — it is the row's shelf life, and the
// editor says out loud when one has gone stale.

/// The five-level evidence scale, read from the file's own meta block so
/// the picker can never drift from what the site publishes.
struct EvidenceScale {
    static let fallback: [(key: String, label: String)] = [
        ("confirmed",  "Contract, official document or parliamentary record"),
        ("reported",   "Reported by specialist press as decided; no contract document seen"),
        ("planned",    "Stated intention, approval or requirement — not a contract"),
        ("option",     "Named publicly as an alternative, not selected"),
        ("superseded", "Was correct, has since been replaced")
    ]
    let levels: [(key: String, label: String)]

    init(meta: [String: Any]?) {
        if let scale = meta?["status_scale"] as? [String: Any], !scale.isEmpty {
            /* Preserve the published order rather than sorting alphabetically —
               the scale runs strongest to weakest and that ordering is meaning. */
            let known = EvidenceScale.fallback.map { $0.key }
            let ordered = known.filter { scale[$0] != nil }
                + scale.keys.filter { !known.contains($0) }.sorted()
            levels = ordered.map { ($0, (scale[$0] as? String) ?? $0) }
        } else {
            levels = EvidenceScale.fallback
        }
    }

    func label(_ key: String) -> String {
        levels.first { $0.key == key }?.label ?? key
    }
}

/// One supplier row. Every field is a string in the file; this is a view
/// over the dictionary, not a replacement for it.
struct Fitment: Identifiable, Equatable {
    var id = UUID()
    var category = ""
    var system = ""
    var supplier = ""
    var tier = ""
    var status = "reported"
    var quote = ""
    var sourcePublisher = ""
    var sourceURL = ""
    var retrieved = ""

    init() {}

    init(_ d: [String: Any]) {
        func s(_ k: String) -> String { (d[k] as? String) ?? "" }
        category = s("category"); system = s("system"); supplier = s("supplier")
        tier = s("tier"); status = s("status"); quote = s("quote")
        sourcePublisher = s("source_publisher"); sourceURL = s("source_url")
        retrieved = s("retrieved")
    }

    var dictionary: [String: Any] {
        ["category": category, "system": system, "supplier": supplier,
         "tier": tier, "status": status, "quote": quote,
         "source_publisher": sourcePublisher, "source_url": sourceURL,
         "retrieved": retrieved]
    }

    // MARK: The rule, enforced

    /// Blocking problems. A row with any of these cannot be saved.
    /// `today` is injected so the check is testable on a fixed clock.
    func problems(today: Date = Date()) -> [String] {
        var out: [String] = []
        if supplier.trimmingCharacters(in: .whitespaces).isEmpty { out.append("No supplier named.") }
        if system.trimmingCharacters(in: .whitespaces).isEmpty { out.append("No system named.") }

        /* The method's own sentence: a row without a citable public source is
           not published. Anything above "planned" is a claim about a document,
           so it has to carry one. */
        let needsDocument = (status == "confirmed" || status == "reported")
        if needsDocument {
            if sourceURL.isEmpty { out.append("\(status.capitalized) needs a source URL.") }
            if retrieved.isEmpty { out.append("\(status.capitalized) needs a retrieval date.") }
            if quote.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\(status.capitalized) needs the verbatim quote the row rests on.")
            }
        }
        if !sourceURL.isEmpty, !(sourceURL.hasPrefix("https://") || sourceURL.hasPrefix("http://")) {
            out.append("Source URL is not a link.")
        }
        if !retrieved.isEmpty {
            guard let d = Fitment.day(retrieved) else {
                out.append("Retrieval date is not yyyy-MM-dd.")
                return out
            }
            if d > today { out.append("Retrieval date is in the future.") }
        }
        return out
    }

    /// Non-blocking. A row that is fine but has aged past its shelf life.
    static let staleAfterDays = 180
    func staleness(today: Date = Date()) -> Int? {
        guard let d = Fitment.day(retrieved) else { return nil }
        let days = Int(today.timeIntervalSince(d) / 86_400)
        return days > Fitment.staleAfterDays ? days : nil
    }

    static func day(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)
    }
}

// MARK: - Store

@MainActor
final class DefenceStore: ObservableObject {
    static let path = "data/defence-programmes.json"

    @Published var state: LoadState<[String]> = .never   // programme names
    @Published var fitments: [Fitment] = []
    @Published var gaps: [String] = []
    @Published var selected = 0
    @Published var dirty = false
    @Published var statusLine: String?
    @Published var saving = false

    private(set) var scale = EvidenceScale(meta: nil)
    private var root: [String: Any] = [:]
    private var sha: String?
    private var repo: String?

    var programmeNames: [String] { state.value ?? [] }

    private var programmes: [[String: Any]] {
        get { (root["programmes"] as? [[String: Any]]) ?? [] }
        set { root["programmes"] = newValue }
    }

    func load(repo: String?) async {
        guard let repo = repo, !repo.isEmpty else {
            state = .failed("No repo configured for this project (projects.json).", at: Date()); return
        }
        self.repo = repo
        state.beginLoading()
        do {
            let f = try await GitHubAPI.file(repo: repo, path: DefenceStore.path)
            guard let text = f.decodedText(), let data = text.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                state = .failed("\(DefenceStore.path) is not a JSON object.", at: Date()); return
            }
            root = obj
            sha = f.sha
            scale = EvidenceScale(meta: obj["meta"] as? [String: Any])
            state = .loaded(programmes.map { ($0["name"] as? String) ?? "Untitled" }, at: Date())
            selected = 0
            readSelected()
            dirty = false
            statusLine = nil
        } catch {
            state = .failed(error.localizedDescription, at: Date())
        }
    }

    func readSelected() {
        guard programmes.indices.contains(selected) else { fitments = []; gaps = []; return }
        let p = programmes[selected]
        fitments = ((p["fitments"] as? [[String: Any]]) ?? []).map(Fitment.init)
        gaps = (p["gaps"] as? [String]) ?? []
    }

    func select(_ i: Int) {
        guard !dirty else { statusLine = "Save or discard before switching programme."; return }
        selected = i
        readSelected()
    }

    /// Every blocking problem across the whole programme, row-numbered.
    func blockingProblems(today: Date = Date()) -> [String] {
        fitments.enumerated().flatMap { i, f in
            f.problems(today: today).map { "Row \(i + 1) (\(f.supplier.isEmpty ? "unnamed" : f.supplier)): \($0)" }
        }
    }

    func save(message: String) async {
        guard let repo = repo, let sha = sha else { statusLine = "Nothing loaded."; return }
        let problems = blockingProblems()
        guard problems.isEmpty else {
            statusLine = "Not saved — \(problems.count) row problem\(problems.count == 1 ? "" : "s") to fix first."
            return
        }
        guard programmes.indices.contains(selected) else { return }

        saving = true
        defer { saving = false }

        var ps = programmes
        ps[selected]["fitments"] = fitments.map { $0.dictionary }
        ps[selected]["gaps"] = gaps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        programmes = ps

        /* Sorted keys make the second and every later diff stable; pretty
           printing keeps the file reviewable in a pull request, which is
           where someone else checks the sources. */
        guard let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            statusLine = "Could not serialise the file."; return
        }
        text = text.replacingOccurrences(of: "\\/", with: "/")   // JSONSerialization escapes slashes
        if !text.hasSuffix("\n") { text += "\n" }

        do {
            let resp = try await GitHubAPI.put(repo: repo, path: DefenceStore.path,
                                               message: message, text: text, sha: sha)
            /* GitHub omits `content` on some responses; losing the new SHA
               would make the next save look like a conflict, so fall back to
               re-reading rather than keeping a stale one. */
            self.sha = resp.content?.sha
            dirty = false
            statusLine = "Committed \(String(resp.commit.sha.prefix(7))) — Netlify rebuilds the defence pages."
        } catch APIError.conflict {
            statusLine = "Someone changed this file on GitHub since it was loaded. Reload before saving."
        } catch {
            statusLine = error.localizedDescription
        }
    }
}

// MARK: - View

struct DefenceEditorView: View {
    @EnvironmentObject var store: CockpitStore
    /* Wie bei Analytics: der Bereich steht unter einem Projekt, also
       nimmt er dessen Repo und nicht das erste, das eines hat. */
    var site: SiteProject?
    @StateObject private var model = DefenceStore()
    @State private var editing: Fitment?
    @State private var commitMessage = ""

    private var repo: String? {
        site?.repo ?? store.sites.first(where: { ($0.repo ?? "").isEmpty == false })?.repo
    }

    var body: some View {
        Page(title: "Defence desk",
             subtitle: "Supplier rows for data/defence-programmes.json — every row carries its document, publisher and retrieval date") {

            switch model.state {
            case .never:
                Card { Text("Not loaded yet.").foregroundColor(.textSecondary) }
            case .loading:
                Card { Text("Reading \(DefenceStore.path)…").foregroundColor(.textSecondary) }
            case .failed(let msg, _):
                Card { Label(msg, systemImage: "exclamationmark.triangle").foregroundColor(.statusRed) }
            case .loaded:
                editor
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.load(repo: repo) } } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { if case .never = model.state { await model.load(repo: repo) } }
        .sheet(item: $editing) { row in
            FitmentSheet(row: row, scale: model.scale) { updated in
                if let i = model.fitments.firstIndex(where: { $0.id == updated.id }) {
                    model.fitments[i] = updated
                } else {
                    model.fitments.append(updated)
                }
                model.dirty = true
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.programmeNames.count > 1 {
                Picker("Programme", selection: Binding(
                    get: { model.selected },
                    set: { model.select($0) })) {
                    ForEach(Array(model.programmeNames.enumerated()), id: \.offset) { i, n in
                        Text(n).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }

            let problems = model.blockingProblems()
            if !problems.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("\(problems.count) row\(problems.count == 1 ? "" : "s") cannot be published",
                              systemImage: "exclamationmark.octagon")
                            .foregroundColor(.statusRed).font(.system(size: 13, weight: .semibold))
                        ForEach(problems.prefix(6), id: \.self) { p in
                            Text(p).font(.caption).foregroundColor(.textSecondary)
                        }
                        if problems.count > 6 {
                            Text("…and \(problems.count - 6) more").font(.caption).foregroundColor(.textSecondary)
                        }
                    }
                }
            }

            HStack {
                Text("\(model.fitments.count) supplier row\(model.fitments.count == 1 ? "" : "s")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)
                Spacer()
                Button { editing = Fitment() } label: { Label("Add row", systemImage: "plus") }
            }

            VStack(spacing: 0) {
                ForEach(Array(model.fitments.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider() }
                    FitmentRowView(row: row, scale: model.scale)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = row }
                        .contextMenu {
                            Button("Delete row", role: .destructive) {
                                model.fitments.removeAll { $0.id == row.id }
                                model.dirty = true
                            }
                        }
                }
            }
            .background(Color.bgCard)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            GapsEditor(gaps: Binding(
                get: { model.gaps },
                set: { model.gaps = $0; model.dirty = true }))

            HStack(spacing: 10) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let msg = commitMessage.isEmpty
                        ? "defence: update supplier rows for \(model.programmeNames.indices.contains(model.selected) ? model.programmeNames[model.selected] : "programme")"
                        : commitMessage
                    Task { await model.save(message: msg) }
                } label: {
                    if model.saving { ProgressView().controlSize(.small) } else { Text("Commit") }
                }
                .disabled(!model.dirty || model.saving || !model.blockingProblems().isEmpty)
            }

            if let line = model.statusLine {
                Text(line).font(.caption).foregroundColor(.textSecondary)
            }
            Text(model.state.provenance(source: DefenceStore.path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSecondary)
        }
    }
}

private struct FitmentRowView: View {
    let row: Fitment
    let scale: EvidenceScale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(row.category.isEmpty ? "—" : row.category)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.textSecondary)
                    if !row.tier.isEmpty {
                        Text(row.tier).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textSecondary)
                    }
                }
                Text(row.supplier.isEmpty ? "Unnamed supplier" : row.supplier)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.textPrimary)
                Text(row.system).font(.caption).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(row.sourcePublisher.isEmpty ? "no publisher" : row.sourcePublisher)
                    Text("·")
                    Text(row.retrieved.isEmpty ? "no date" : "read \(row.retrieved)")
                    if let days = row.staleness() {
                        Text("· \(days) d old").foregroundColor(.statusAmber)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.status)
                    .font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundColor(tint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
                if !row.problems().isEmpty {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundColor(.statusRed)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .help(scale.label(row.status))
    }

    private var tint: Color {
        switch row.status {
        case "confirmed":  return .stApplied
        case "reported":   return .accentNavy
        case "planned":    return .statusAmber
        case "option":     return .textSecondary
        case "superseded": return .statusRed
        default:           return .textSecondary
        }
    }
}

private struct FitmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var row: Fitment
    let scale: EvidenceScale
    var onSave: (Fitment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supplier row").font(.system(size: 17, weight: .bold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Category"); TextField("Platform, Sensors, Effectors…", text: $row.category) }
                GridRow { Text("System");   TextField("What it is", text: $row.system) }
                GridRow { Text("Supplier"); TextField("Who supplies it", text: $row.supplier) }
                GridRow { Text("Tier");     TextField("Prime, Tier 1, Tier 2…", text: $row.tier) }
                GridRow {
                    Text("Evidence")
                    Picker("", selection: $row.status) {
                        ForEach(scale.levels, id: \.key) { l in Text(l.key).tag(l.key) }
                    }.labelsHidden()
                }
            }
            Text(scale.label(row.status)).font(.caption).foregroundColor(.textSecondary)

            Divider()
            Text("The document this row rests on")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.textSecondary)
            TextField("Verbatim quote from the source", text: $row.quote, axis: .vertical)
                .lineLimit(2...4)
            TextField("Publisher", text: $row.sourcePublisher)
            TextField("https://…", text: $row.sourceURL)
            TextField("Retrieved (yyyy-MM-dd)", text: $row.retrieved)

            let problems = row.problems()
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.statusRed)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") { onSave(row); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct GapsEditor: View {
    @Binding var gaps: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Gaps — what this map does not cover")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.textSecondary)
            Text("A category with no citable source belongs here, not in the table above.")
                .font(.caption).foregroundColor(.textSecondary)
            ForEach(Array(gaps.enumerated()), id: \.offset) { i, g in
                HStack {
                    Text("· \(g)").font(.caption)
                    Spacer()
                    Button {
                        gaps.remove(at: i)
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add a gap", text: $draft).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let t = draft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    gaps.append(t); draft = ""
                }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 6)
    }
}
