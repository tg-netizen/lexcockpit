import SwiftUI

/*  LayoutTab.swift — moving the website around without touching HTML
 *  ═══════════════════════════════════════════════════════════════════
 *  The body of a converted page is a list of sections, each a list of
 *  blocks. Here they can be reordered, rewritten, added and removed, and
 *  the result is written back to data/pages/<id>.json in the repo. The
 *  next deploy renders it. No HTML is edited by hand at any point, and
 *  nothing this app does not understand is destroyed: a block of a type
 *  it cannot edit still appears, still moves, and goes back out exactly
 *  as it came in.
 *
 *  ── Why up and down buttons rather than dragging ──────────────────────
 *  Dragging is the obvious gesture and the wrong one here. A page has a
 *  handful of blocks, the list scrolls, and a drag that crosses a scroll
 *  boundary is the single most annoying interaction on a Mac. Two buttons
 *  are unglamorous, exact, and work with the keyboard.
 */

struct LayoutTabView: View {
    @ObservedObject var model: WorkspaceModel
    let site: SiteProject
    @State private var selected: String?
    @State private var openBlock: UUID?

    private var page: SitePage? {
        model.pages.first { $0.id == (selected ?? model.pages.first?.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.pagesLoading && model.pages.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the page files").font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                    }
                } else if let err = model.pagesError {
                    ErrorCard(title: "Could not read the layouts", detail: err) {
                        Task { await model.loadPages(force: true) }
                    }
                } else if model.pagesState.isConfirmedEmpty {
                    EmptyCard(
                        title: "No page is on blocks yet",
                        detail: "A page becomes editable here once its body sits in "
                              + "data/pages and the page carries the LAYOUT markers. "
                              + "Until then its HTML is written by hand and this panel "
                              + "would only be able to lie about it.",
                        systemImage: "square.stack.3d.up")
                } else if case .never = model.pagesState {
                    EmptyCard(title: "Not read yet",
                              detail: "The layouts are read from the repo when you open this panel.",
                              systemImage: "clock")
                } else if let p = page {
                    editor(p)
                }
            }
            .padding(20)
        }
        .background(Color.bgPage)
        .task { await model.loadPages() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                if let p = page, model.pagesDirty.contains(p.id) {
                    if model.pageSaving == p.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save to the repo") { Task { await model.savePage(p.id) } }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentNavySolid)
                    }
                }
                Button {
                    Task { await model.loadPages(force: true) }
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentNavy)
                .disabled(model.pagesLoading || !model.pagesDirty.isEmpty)
                .help(model.pagesDirty.isEmpty
                      ? "Read the page files again"
                      : "Save first, or the unsaved change would be read over")
            }
            Text("The body of a page, as movable parts. Saving writes data/pages back to the "
                 + "repo; the site rebuilds it on the next deploy.")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.pageSaveError {
                ErrorCard(title: "Not saved", detail: err, retry: nil)
            }

            if model.pages.count > 1 {
                Picker("", selection: Binding(
                    get: { selected ?? model.pages.first?.id ?? "" },
                    set: { selected = $0 })) {
                    ForEach(model.pages) { p in Text(p.title).tag(p.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            if let p = page {
                HStack(spacing: 10) {
                    Text("/" + p.target)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textSecondary)
                    Text("\(p.sections.count) sections, \(p.blockCount) blocks")
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                    if model.pagesDirty.contains(p.id) {
                        Pill(text: "unsaved", color: .statusAmber)
                    }
                }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder private func editor(_ p: SitePage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(p.sections.enumerated()), id: \.element.id) { si, sec in
                sectionCard(p, si, sec)
            }
            Button {
                var page = p
                page.sections.append(PageSection(
                    fields: ["id": .string("s\(page.sections.count + 1)"),
                             "heading": .string("New section")],
                    blocks: []))
                model.updatePage(page)
            } label: {
                Label("Add section", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentNavy)
        }
    }

    private func sectionCard(_ p: SitePage, _ si: Int, _ sec: PageSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("SECTION \(si + 1)")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundColor(.textSecondary)
                Spacer()
                moveButtons(up: si > 0, down: si < p.sections.count - 1,
                            onUp: { move(p, section: si, by: -1) },
                            onDown: { move(p, section: si, by: 1) })
                Button {
                    var page = p; page.sections.remove(at: si); model.updatePage(page)
                } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(.statusRed)
                .help("Remove this section and everything in it")
            }

            field("Eyebrow", sec.eyebrow.joined(separator: " · ")) { v in
                var page = p
                page.sections[si].eyebrow = v.split(separator: "·")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                model.updatePage(page)
            }
            field("Heading", sec.heading) { v in
                var page = p; page.sections[si].heading = v; model.updatePage(page)
            }

            Divider().opacity(0.5)

            ForEach(Array(sec.blocks.enumerated()), id: \.element.id) { bi, block in
                blockRow(p, si, bi, block, count: sec.blocks.count)
            }

            addBlockMenu(p, si)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    // MARK: One block

    private func blockRow(_ p: SitePage, _ si: Int, _ bi: Int,
                          _ block: PageBlock, count: Int) -> some View {
        let open = openBlock == block.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(block.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                    .foregroundColor(block.isEditable ? .accentNavy : .statusAmber)
                    .frame(width: 92, alignment: .leading)
                Text(block.summary.isEmpty ? "(empty)" : block.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.textPrimary)
                    .lineLimit(open ? nil : 1)
                Spacer(minLength: 8)
                moveButtons(up: bi > 0, down: bi < count - 1,
                            onUp: { move(p, si, block: bi, by: -1) },
                            onDown: { move(p, si, block: bi, by: 1) })
                Button {
                    openBlock = open ? nil : block.id
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundColor(.textSecondary)
                .disabled(!block.isEditable)
                .help(block.isEditable ? "Edit" : "This build cannot edit this type, only move it")
                Button {
                    var page = p; page.sections[si].blocks.remove(at: bi); model.updatePage(page)
                } label: { Image(systemName: "trash").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundColor(.statusRed)
            }
            if open, block.isEditable {
                blockEditor(p, si, bi, block)
                    .padding(.leading, 92)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private func blockEditor(_ p: SitePage, _ si: Int, _ bi: Int,
                                          _ block: PageBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch block.type {
            case "lead", "prose", "subhead", "limit", "hint":
                multiline(block.text) { v in
                    write(p, si, bi) { $0.fields["text"] = .string(v) }
                }
            case "next":
                field("Label", block.fields["label"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["label"] = .string(v) }
                }
                field("Link", block.fields["href"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["href"] = .string(v) }
                }
            case "subheadUnused":
                EmptyView()
            case "image":
                field("File in the repo", block.fields["src"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["src"] = .string(v) }
                }
                field("Alt text, what the image shows",
                      block.fields["alt"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["alt"] = .string(v) }
                }
                field("Caption", block.fields["caption"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["caption"] = .string(v) }
                }
                field("Credit and licence", block.fields["credit"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["credit"] = .string(v) }
                }
                Text("An image without alt text is not there for part of your readers, and "
                     + "without a credit line this desk cannot show it at all.")
                    .font(.system(size: 10)).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case "counts":
                lines("One per line", block.fields["items"]?.stringList ?? []) { v in
                    write(p, si, bi) { $0.fields["items"] = .array(v.map { .string($0) }) }
                }
            case "gaps":
                field("Heading", block.fields["heading"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["heading"] = .string(v) }
                }
                lines("One gap per line", block.fields["items"]?.stringList ?? []) { v in
                    write(p, si, bi) { $0.fields["items"] = .array(v.map { .string($0) }) }
                }
            case "sources":
                field("Summary", block.fields["summary"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["summary"] = .string(v) }
                }
                multiline(block.fields["note"]?.stringValue ?? "") { v in
                    write(p, si, bi) { $0.fields["note"] = .string(v) }
                }
            case "tool":
                instrumentPicker(p, si, bi, block)
            case "table":
                Text("Tables are read and moved here, but edited in the page file. "
                     + "A table editor that cannot do columns properly is worse than none.")
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    /// Choosing an instrument from the register the Instruments panel built,
    /// so a tool block can never name one that does not exist.
    @ViewBuilder private func instrumentPicker(_ p: SitePage, _ si: Int, _ bi: Int,
                                               _ block: PageBlock) -> some View {
        let current = block.fields["attribute"]?.stringValue ?? ""
        if model.tools.isEmpty {
            HStack(spacing: 8) {
                Text("The register has not been read yet.")
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
                Button("Read it") { Task { await model.loadTools() } }
                    .buttonStyle(.plain).foregroundColor(.accentNavy)
                    .font(.system(size: 11))
            }
        } else {
            Picker("Instrument", selection: Binding(
                get: { current },
                set: { v in write(p, si, bi) { $0.fields["attribute"] = .string(v) } })) {
                Text("(none)").tag("")
                ForEach(model.tools) { t in
                    Text("\(t.name)  ·  \(t.attribute)").tag(t.attribute)
                }
            }
            .frame(maxWidth: 360)
            field("Container class", block.fields["cls"]?.stringValue ?? "") { v in
                write(p, si, bi) { $0.fields["cls"] = .string(v) }
            }
            if let t = model.tools.first(where: { $0.attribute == current }),
               let script = t.script {
                Text("Driven by " + script + ". The page must load that script, or the "
                     + "instrument sits there and does nothing.")
                    .font(.system(size: 10)).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Adding

    private func addBlockMenu(_ p: SitePage, _ si: Int) -> some View {
        Menu {
            ForEach(PageBlock.editable, id: \.self) { t in
                Button(PageBlock.make(t).label) {
                    var page = p
                    page.sections[si].blocks.append(PageBlock.make(t))
                    model.updatePage(page)
                }
            }
        } label: {
            Label("Add block", systemImage: "plus").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundColor(.accentNavy)
    }

    // MARK: Small parts

    private func moveButtons(up: Bool, down: Bool,
                             onUp: @escaping () -> Void,
                             onDown: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: onUp) { Image(systemName: "arrow.up").font(.system(size: 10)) }
                .buttonStyle(.plain).disabled(!up)
                .foregroundColor(up ? .accentNavy : .textSecondary.opacity(0.4))
                .help("Move up")
            Button(action: onDown) { Image(systemName: "arrow.down").font(.system(size: 10)) }
                .buttonStyle(.plain).disabled(!down)
                .foregroundColor(down ? .accentNavy : .textSecondary.opacity(0.4))
                .help("Move down")
        }
    }

    private func field(_ label: String, _ value: String,
                       _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.3)
                .foregroundColor(.textSecondary)
            TextField("", text: Binding(get: { value }, set: set))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func multiline(_ value: String,
                           _ set: @escaping (String) -> Void) -> some View {
        TextEditor(text: Binding(get: { value }, set: set))
            .font(.system(size: 12))
            .frame(minHeight: 80)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.bgPage))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func lines(_ label: String, _ items: [String],
                       _ set: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.3)
                .foregroundColor(.textSecondary)
            multiline(items.joined(separator: "\n")) { v in
                set(v.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }

    // MARK: Edits

    private func write(_ p: SitePage, _ si: Int, _ bi: Int,
                       _ change: (inout PageBlock) -> Void) {
        var page = p
        change(&page.sections[si].blocks[bi])
        model.updatePage(page)
    }

    private func move(_ p: SitePage, section i: Int, by d: Int) {
        var page = p
        let j = i + d
        guard j >= 0, j < page.sections.count else { return }
        page.sections.swapAt(i, j)
        model.updatePage(page)
    }

    private func move(_ p: SitePage, _ si: Int, block i: Int, by d: Int) {
        var page = p
        let j = i + d
        guard j >= 0, j < page.sections[si].blocks.count else { return }
        page.sections[si].blocks.swapAt(i, j)
        model.updatePage(page)
    }
}
