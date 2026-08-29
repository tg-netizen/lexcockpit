import SwiftUI

/*  DesignTab.swift — the site's design, as a panel
 *  ═══════════════════════════════════════════════════════════════════
 *  Fifty-one values decide what lexdigestglobal.com looks like. They are
 *  named, everything else in the stylesheet refers to them, and until now
 *  changing one meant opening a nine thousand line CSS file and hoping.
 *
 *  Two things make this more than a list of colour wells.
 *
 *  First, the contrast is measured, here, against the pairs the site
 *  actually puts together. A palette panel that lets you pick a grey for
 *  body text and says nothing while it falls to 3.1 is worse than no
 *  panel, because it makes the mistake feel considered. Every ratio on
 *  this screen is computed from the values as they stand, and it moves
 *  while you type.
 *
 *  Second, dark mode is edited as one thing. The stylesheet declares it
 *  twice, for the reader who chose it and the reader whose system chose
 *  for them, and those two have to agree. Here they are one field.
 */

struct DesignTabView: View {
    @ObservedObject var model: WorkspaceModel
    /// Which theme the numbers and swatches are shown for. Not a setting,
    /// a lens: the file always holds both.
    @State private var showDark = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.designLoading && model.design == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the stylesheet").font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                    }
                } else if let err = model.designError {
                    ErrorCard(title: "Could not read the design", detail: err) {
                        Task { await model.loadDesign(force: true) }
                    }
                } else if case .never = model.designState {
                    EmptyCard(title: "Not read yet",
                              detail: "The tokens are read from assets/css/style.css when you open this panel.",
                              systemImage: "clock")
                } else if let sheet = model.design {
                    contrastCard(sheet)
                    ForEach(DesignToken.groupOrder, id: \.self) { g in
                        let rows = sheet.tokens.filter { $0.group == g }
                        if !rows.isEmpty { groupCard(g, rows, sheet) }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.bgPage)
        .task { await model.loadDesign() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Design")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                if let sheet = model.design, !sheet.changed.isEmpty {
                    Text("\(sheet.changed.count) changed")
                        .font(.system(size: 11)).foregroundColor(.statusAmber)
                    Button("Undo all") { model.revertDesign() }
                        .buttonStyle(.plain).foregroundColor(.accentNavy)
                        .font(.system(size: 12))
                    if model.designSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save to the repo") { Task { await model.saveDesign() } }
                            .buttonStyle(.borderedProminent).tint(.accentNavySolid)
                    }
                }
                Button {
                    Task { await model.loadDesign(force: true) }
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.accentNavy)
                .disabled(model.designLoading || !(model.design?.changed.isEmpty ?? true))
            }

            Text("Every colour, measure and timing the website uses. Changing one changes "
                 + "the whole site, because everything else in the stylesheet refers to "
                 + "these names rather than repeating their values.")
                .font(.system(size: 12)).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.designSaveError {
                ErrorCard(title: "Not saved", detail: err, retry: nil)
            }

            HStack(spacing: 12) {
                Picker("", selection: $showDark) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                if let sheet = model.design {
                    Text("\(sheet.tokens.count) tokens, "
                         + "\(sheet.tokens.filter { $0.dark != nil }.count) with a dark value")
                        .font(.system(size: 11)).foregroundColor(.textSecondary)
                    if sheet.blocksFound < 3 {
                        Pill(text: "only \(sheet.blocksFound) of 3 blocks found",
                             color: .statusAmber)
                    }
                    if !sheet.darkOutOfSync.isEmpty {
                        Pill(text: "\(sheet.darkOutOfSync.count) dark values in one block only",
                             color: .statusAmber)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: Contrast

    private func contrastCard(_ sheet: DesignSheet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showDark ? "CONTRAST, DARK" : "CONTRAST, LIGHT")
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundColor(.textSecondary)
            Text("Measured from the values as they stand now, on the pairs the site actually "
                 + "puts together. WCAG 2.1.")
                .font(.system(size: 11)).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ContrastPair.all) { pair in
                let fg = sheet.tokens.first { $0.name == pair.fg }
                let bg = sheet.tokens.first { $0.name == pair.bg }
                let fgV = fg.map { showDark ? ($0.dark ?? $0.light) : $0.light } ?? ""
                let bgV = bg.map { showDark ? ($0.dark ?? $0.light) : $0.light } ?? ""
                let ratio = CSSColour.contrast(fgV, bgV, in: sheet.tokens, dark: showDark)

                HStack(spacing: 8) {
                    swatch(bgV, sheet)
                    swatch(fgV, sheet)
                    Text(pair.label)
                        .font(.system(size: 12)).foregroundColor(.textPrimary)
                    Spacer(minLength: 8)
                    if let r = ratio {
                        Text(String(format: "%.2f", r))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(r >= pair.needs ? .statusGreen : .statusRed)
                        Text("needs \(String(format: "%.2g", pair.needs))")
                            .font(.system(size: 10)).foregroundColor(.textSecondary)
                    } else {
                        /* Not computable is said as not computable. A
                           missing number must never be shown as 1.00. */
                        Text("not a plain colour")
                            .font(.system(size: 10)).foregroundColor(.textSecondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    // MARK: Token groups

    private func groupCard(_ group: String, _ rows: [DesignToken],
                           _ sheet: DesignSheet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundColor(.textSecondary)
                .padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().opacity(0.5) }
                tokenRow(t, sheet)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func tokenRow(_ t: DesignToken, _ sheet: DesignSheet) -> some View {
        HStack(alignment: .center, spacing: 10) {
            swatch(showDark ? (t.dark ?? t.light) : t.light, sheet)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("--" + t.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textPrimary)
                    if t.isChanged { Pill(text: "changed", color: .statusAmber) }
                }
                if t.dark == nil && t.kind == .colour {
                    /* Worth saying: a colour with no dark value is the
                       same in both themes, which is sometimes right and
                       sometimes an oversight. */
                    Text("same in both themes")
                        .font(.system(size: 9)).foregroundColor(.textSecondary)
                }
            }
            .frame(width: 200, alignment: .leading)

            TextField("", text: Binding(
                get: { showDark ? (t.dark ?? t.light) : t.light },
                set: { v in
                    if showDark {
                        /* Typing a dark value where there was none creates
                           one, in both dark blocks. */
                        model.setToken(t.name, light: nil, dark: v)
                    } else {
                        model.setToken(t.name, light: v, dark: nil)
                    }
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(showDark && t.dark == nil)
                .help(showDark && t.dark == nil
                      ? "This token has no separate dark value. Add one below."
                      : "The value as it stands in style.css")

            if showDark && t.dark == nil {
                Button("Add dark") {
                    model.setToken(t.name, light: nil, dark: t.light)
                }
                .buttonStyle(.plain).foregroundColor(.accentNavy)
                .font(.system(size: 11))
                .help("Start from the light value and change it from there")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func swatch(_ value: String, _ sheet: DesignSheet) -> some View {
        if let c = CSSColour.swatch(value, in: sheet.tokens, dark: showDark) {
            RoundedRectangle(cornerRadius: 2)
                .fill(c)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.cardBorder, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.cardBorder, lineWidth: 1)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "minus")
                    .font(.system(size: 8)).foregroundColor(.textSecondary))
        }
    }
}
