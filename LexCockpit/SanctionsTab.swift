import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/*  SanctionsTab.swift — the desk the app was missing
 *  ═══════════════════════════════════════════════════════════════════
 *  lexdigestglobal.com has four desks in its own nav.json: News,
 *  Regulation, Sanctions, Defence. Three of them had a counterpart in
 *  this app. Sanctions had none, so the largest single body of pages on
 *  the site, a dossier per regime, was invisible from the workspace that
 *  is supposed to be the way in.
 *
 *  This is deliberately not an editor. Writing a dossier editor before
 *  knowing what editing one means would be building a room nobody asked
 *  for. What it is, is the actual stock: every dossier in the repo,
 *  counted, named and openable. That is the smallest thing that is true,
 *  and it beats an empty pane with a promise on it.
 */

/// One country dossier, as it exists in the repo.
struct SiteDossier: Identifiable, Hashable {
    /// politics/sanctions/bosnia-and-herzegovina.html
    let path: String
    /// bosnia-and-herzegovina
    let slug: String

    var id: String { path }

    /// The slug read back as a name. Derived, not stored, so a dossier
    /// added tomorrow appears under a sensible name without anyone
    /// maintaining a table. Small words stay lowercase the way they do in
    /// a country name: Bosnia and Herzegovina, not Bosnia And Herzegovina.
    var name: String {
        let small: Set<String> = ["and", "of", "the", "an", "a"]
        let parts = slug.split(separator: "-").map(String.init)
        return parts.enumerated().map { i, w in
            (i > 0 && small.contains(w)) ? w : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// Regimes that are not a country. They read oddly in an A to Z of
    /// countries, so they are marked rather than silently mixed in.
    var isHorizontal: Bool {
        ["horizontal", "cyber", "human-rights", "terrorism", "chemical-weapons"]
            .contains(slug)
    }
}

struct SanctionsTabView: View {
    @ObservedObject var model: WorkspaceModel
    let site: SiteProject
    @State private var query = ""

    private var shown: [SiteDossier] {
        guard !query.isEmpty else { return model.dossiers }
        return model.dossiers.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.dossiersLoading && model.dossiers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the repo").font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                    }
                } else if let err = model.dossiersError {
                    ErrorCard(title: "Could not read the dossiers", detail: err) {
                        Task { await model.loadDossiers(force: true) }
                    }
                } else if model.dossiersState.isConfirmedEmpty {
                    EmptyCard(title: "No dossier in the repo",
                              detail: "Nothing under politics/sanctions. That is a finding: "
                                    + "the desk exists on the site but has no pages behind it.",
                              systemImage: "hand.raised")
                } else if case .never = model.dossiersState {
                    EmptyCard(title: "Not read yet",
                              detail: "The stock is counted from the repo when you open this panel.",
                              systemImage: "clock")
                } else {
                    list
                }
            }
            .padding(20)
        }
        .background(Color.bgPage)
        .task { await model.loadDossiers() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sanctions dossiers")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Button {
                    Task { await model.loadDossiers(force: true) }
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentNavy)
                .disabled(model.dossiersLoading)
            }
            Text("One page per regime, counted from the repo. This panel reads the stock; "
                 + "the pages themselves are written on the site.")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                let horiz = model.dossiers.filter(\.isHorizontal).count
                stat("\(model.dossiers.count)", "dossiers")
                stat("\(model.dossiers.count - horiz)", "countries")
                stat("\(horiz)", "horizontal regimes")
                Spacer()
                if let stamp = model.dossiersState.stamp {
                    Text("read " + Self.stampText(stamp))
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                        .help(stamp.description)
                }
            }

            if !model.dossiers.isEmpty {
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
        }
    }

    private static func stampText(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(.textSecondary)
        }
    }

    @ViewBuilder private var list: some View {
        if shown.isEmpty {
            Text("Nothing matches \"\(query)\".")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, d in
                    if idx > 0 { Divider() }
                    row(d)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
            if !query.isEmpty {
                Text("Showing \(shown.count) of \(model.dossiers.count).")
                    .font(.system(size: 11))
                    .foregroundColor(.textSecondary)
            }
        }
    }

    private func row(_ d: SiteDossier) -> some View {
        HStack(spacing: 8) {
            Text(d.name)
                .font(.system(size: 13))
                .foregroundColor(.textPrimary)
            if d.isHorizontal {
                Pill(text: "horizontal", color: .accentNavy)
            }
            Spacer()
            Text("/" + d.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSecondary)
            Button { open(d) } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentNavy)
            .help("Open /" + d.path)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { open(d) }
    }

    private func open(_ d: SiteDossier) {
        guard let base = site.url else { return }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + "/" + d.path) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
