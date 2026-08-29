import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/*  ToolsTab.swift — the instruments the website carries
 *  ═══════════════════════════════════════════════════════════════════
 *  The site is built on a rule: every claim gets an instrument the reader
 *  can move. There are thirty of them now, spread across the desks, and
 *  until this view there was no list of them anywhere. Not in the app, not
 *  on the site. You could only find an instrument by remembering which
 *  page it sat on.
 *
 *  The register is derived, never stored. WorkspaceModel.loadTools reads
 *  the scripts and the pages out of the repo and works out which
 *  instrument each script boots and which pages mount it. A list kept by
 *  hand goes stale in the first busy week, and a stale register is worse
 *  than none because it reads as coverage.
 *
 *  What that buys beyond a list: an instrument mounted on a page that
 *  never loads its script is dead under the reader's cursor, and a script
 *  no page mounts any more is weight nobody carries. Neither shows up
 *  anywhere else. Both show up here, at the top, because they are the
 *  reason to open this panel at all.
 */

// MARK: - Model

/// One instrument, as read out of the repo.
struct SiteTool: Identifiable, Hashable {
    /// The attribute the container carries, e.g. `data-fundflow`. This is
    /// the ground truth and is always shown next to the name.
    let attribute: String
    /// An editorial label for the attribute. Convenience only, which is
    /// why the attribute stays visible beside it.
    let name: String
    /// The file in assets/js that boots it.
    let script: String?
    /// Every page that mounts it.
    let pages: [String]
    /// The subset of those pages that never load `script`. On those pages
    /// the instrument is in the HTML and does nothing.
    let unwiredPages: [String]

    var id: String { attribute }

    enum State {
        /// Mounted somewhere that does not load its script. A reader can
        /// click this and nothing happens.
        case dead
        /// The script boots nothing: no page mounts the attribute.
        case orphan
        /// Mounted, and driven everywhere it is mounted.
        case wired
    }

    var state: State {
        if !unwiredPages.isEmpty { return .dead }
        if pages.isEmpty { return .orphan }
        return .wired
    }

    /// Sort key: findings before working instruments.
    var rank: Int {
        switch state {
        case .dead:   return 0
        case .orphan: return 1
        case .wired:  return 2
        }
    }

    /* The labels are editorial: an attribute reads `data-ff` and a person
       needs "Funding route channel". Anything not named here still appears,
       under a label derived from its own attribute, so an instrument shows
       up on the day it ships rather than the day somebody remembers it. */
    private static let NAMES: [String: String] = [
        "data-atlas-country":     "Atlas country card",
        "data-awards":            "Contract awards",
        "data-bayes":             "What an alert is worth",
        "data-bottleneck":        "Signal path bottleneck",
        "data-cascade":           "Orbital cascade",
        "data-clocks":            "The decision window",
        "data-contact":           "Orbital contact window",
        "data-diff":              "Automatic rule reader",
        "data-drift":             "Position drift",
        "data-eurlex-status":     "EUR-Lex status",
        "data-extractor":         "Pattern extractor",
        "data-filter-dynamic":    "Dynamic filter",
        "data-filter-group":      "Filter group",
        "data-filter-root":       "Filterable table",
        "data-fundflow":          "Funding route channel",
        "data-impl-country":      "Implementation by country",
        "data-intercept":         "Intercept sequence",
        "data-lagebild":          "Report map",
        "data-netz":              "Neural network, walkable",
        "data-press-tracker":     "Press tracker",
        "data-related-briefings": "Related briefings",
        "data-rulegraph":         "Where the rule attaches",
        "data-sandbox":           "Tech lab sandbox",
        "data-sbx":               "The fused picture",
        "data-scope":             "Scope walker",
        "data-screen":            "Supplier screen",
        "data-supply-map":        "Supply map",
        "data-threshold":         "Threshold walker",
        "data-wire":              "Where the model runs",
        "data-zone":              "Risk zones"
    ]

    static func readableName(for attribute: String) -> String {
        if let known = NAMES[attribute] { return known }
        /* Derived, and deliberately plain: "data-foo-bar" becomes
           "Foo bar", so an unnamed instrument looks unnamed. */
        let stem = attribute.hasPrefix("data-")
            ? String(attribute.dropFirst("data-".count)) : attribute
        let words = stem.split(separator: "-").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// What the last scan actually read. A count without its basis is a claim
/// without a date, so the header carries this rather than implying that
/// the register covers everything.
struct ToolScanScope: Equatable {
    var scripts: Int
    var pages: Int
}

// MARK: - Regex helper

extension String {
    /// All captures of `group` for `pattern`, in order.
    func matches(_ pattern: String, group: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                m.numberOfRanges > group ? ns.substring(with: m.range(at: group)) : nil
            }
    }
}

// MARK: - View

struct ToolsTabView: View {
    @ObservedObject var model: WorkspaceModel
    let site: SiteProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.toolsLoading && model.tools.isEmpty {
                    SkeletonStack(count: 5)
                } else if let err = model.toolsError {
                    ErrorCard(title: "Could not read the instruments", detail: err) {
                        Task { await model.loadTools(force: true) }
                    }
                } else if model.toolsState.isConfirmedEmpty {
                    EmptyCard(title: "No instrument found",
                              detail: "The scan read the repo and found no script that mounts one. "
                                    + "That is a finding, not an empty list.",
                              systemImage: "wrench.and.screwdriver")
                } else if case .never = model.toolsState {
                    EmptyCard(title: "Not read yet",
                              detail: "The register is derived from the repo when you open this panel.",
                              systemImage: "clock")
                } else {
                    findings
                    register
                }
            }
            .padding(20)
        }
        .background(Color.bgPage)
        .task { await model.loadTools() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Instruments")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Button {
                    Task { await model.loadTools(force: true) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        Text("Read again").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentNavy)
                .disabled(model.toolsLoading)
            }
            Text("Every interactive tool the site carries, read out of the repo itself. "
                 + "An instrument is counted where a script mounts it by attribute; "
                 + "it is driven where that page also loads the script.")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            basis
        }
    }

    /// The numbers, each with what it rests on.
    private var basis: some View {
        HStack(spacing: 16) {
            stat("\(model.tools.count)", "instruments")
            stat("\(model.tools.reduce(0) { $0 + $1.pages.count })", "mounts")
            let dead = model.tools.filter { $0.state == .dead }.count
            let orphan = model.tools.filter { $0.state == .orphan }.count
            stat("\(dead)", "dead", tint: dead > 0 ? .statusRed : nil)
            stat("\(orphan)", "orphaned", tint: orphan > 0 ? .statusAmber : nil)
            Spacer()
            if model.toolsScanned.pages > 0 {
                /* Umfang UND Zeitpunkt. Der Umfang stand hier schon,
                   der Zeitpunkt fehlte, und das Register wird eine ganze
                   Sitzung lang zwischengespeichert. */
                Text("read \(model.toolsScanned.scripts) scripts, "
                     + "\(model.toolsScanned.pages) pages · "
                     + model.toolsState.provenance(source: "github tree"))
                    .font(.system(size: 11))
                    .foregroundColor(.textSecondary)
            }
            if model.toolsLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(tint ?? .textPrimary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(.textSecondary)
        }
    }

    // MARK: Findings

    /// Dead and orphaned instruments, said plainly before the register.
    @ViewBuilder private var findings: some View {
        let broken = model.tools.filter { $0.state != .wired }
        if !broken.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.statusRed)
                        Text(broken.count == 1 ? "One instrument needs attention"
                                               : "\(broken.count) instruments need attention")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.textPrimary)
                    }
                    ForEach(broken) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            switch tool.state {
                            case .dead:
                                Text("\(tool.name) is in the page but its script is not loaded there, "
                                     + "so a reader clicks it and nothing happens.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textPrimary)
                                ForEach(tool.unwiredPages, id: \.self) { p in
                                    PageLink(path: p,
                                             note: "missing \(tool.script ?? "its script")",
                                             open: open, webPath: webPath)
                                }
                            case .orphan:
                                Text("\(tool.script ?? tool.attribute) boots \(tool.attribute), "
                                     + "but no page mounts it any more.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textPrimary)
                            case .wired:
                                EmptyView()
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Register

    private var register: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The register")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(.textSecondary)
                .padding(.bottom, 8)

            ForEach(Array(model.tools.enumerated()), id: \.element.id) { idx, tool in
                if idx > 0 {
                    Divider().foregroundColor(.cardBorder)
                }
                toolRow(tool)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func toolRow(_ tool: SiteTool) -> some View {
        ToolRow(tool: tool, open: open, webPath: webPath)
    }

    private func webPath(_ p: String) -> String {
        let s = p.hasSuffix("/index.html") ? String(p.dropLast("index.html".count)) : p
        return "/" + s
    }

    private func open(_ path: String) {
        guard let base = site.url else { return }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + webPath(path)) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/* ── One instrument, and the pages it sits on ──────────────────────────
   The page list has to fold. Related briefings is mounted on 38 pages,
   and printed flat it pushed the other twenty-nine instruments off the
   bottom of the panel: the register became a list of sanctions pages
   with a register somewhere underneath it. Three pages is enough to see
   where a thing lives; the rest is available on request.

   A page where the script is missing is never folded away, because that
   is the finding and folding it would be hiding it. */
private struct ToolRow: View {
    let tool: SiteTool
    var open: (String) -> Void
    var webPath: (String) -> String
    @State private var expanded = false

    private static let FOLD_AT = 3

    private var shown: [String] {
        if expanded || tool.pages.count <= Self.FOLD_AT { return tool.pages }
        /* Broken pages first and always visible, then fill up to the fold. */
        let broken = tool.pages.filter { tool.unwiredPages.contains($0) }
        let rest = tool.pages.filter { !tool.unwiredPages.contains($0) }
        return Array((broken + rest).prefix(max(Self.FOLD_AT, broken.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tool.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textPrimary)
                switch tool.state {
                case .dead:   Pill(text: "dead", color: .statusRed)
                case .orphan: Pill(text: "no page", color: .statusAmber)
                case .wired:  EmptyView()
                }
                Spacer()
                Text(tool.attribute)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let s = tool.script {
                    Text(s)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textSecondary)
                }
                if tool.pages.count > 1 {
                    Text("on \(tool.pages.count) pages")
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                }
            }
            ForEach(shown, id: \.self) { p in
                PageLink(path: p,
                         note: tool.unwiredPages.contains(p) ? "script not loaded" : nil,
                         open: open, webPath: webPath)
            }
            if tool.pages.count > shown.count || (expanded && tool.pages.count > Self.FOLD_AT) {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Show fewer"
                                  : "and \(tool.pages.count - shown.count) more")
                        .font(.system(size: 11))
                        .foregroundColor(.accentNavy)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9)
    }

}

/// One page reference: opens the live page, and says when the instrument
/// on it is not actually driven.
private struct PageLink: View {
    let path: String
    let note: String?
    var open: (String) -> Void
    var webPath: (String) -> String

    var body: some View {
        HStack(spacing: 6) {
            Button { open(path) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                    Text(webPath(path)).font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.accentNavy)
            }
            .buttonStyle(.plain)
            .help("Open " + webPath(path))
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.statusRed)
            }
        }
    }
}
