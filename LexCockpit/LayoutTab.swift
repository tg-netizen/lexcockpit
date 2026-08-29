import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

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
    @State private var previewing = false

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
                    if previewing {
                        PagePreview(model: model, page: p, site: site)
                            .frame(minHeight: 520)
                    } else {
                        editor(p)
                    }
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

            Picker("", selection: $previewing) {
                Text("Blocks").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("The preview renders the blocks with the site's own stylesheet, "
                  + "using the same rules as the deploy")

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
                    Text(model.pagesState.provenance(source: "data/pages"))
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
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
            case "heading":
                Picker("Level", selection: Binding(
                    get: { { if case .number(let d) = block.fields["level"] { return Int(d) }
                             return 3 }() },
                    set: { v in write(p, si, bi) { $0.fields["level"] = .number(Double(v)) } })) {
                    Text("Heading 3").tag(3)
                    Text("Heading 4").tag(4)
                }
                .pickerStyle(.segmented).frame(width: 220)
                field("Text", block.text) { v in
                    write(p, si, bi) { $0.fields["text"] = .string(v) }
                }
                field("Anchor id, optional", block.fields["id"]?.stringValue ?? "") { v in
                    write(p, si, bi) {
                        if v.isEmpty { $0.fields.removeValue(forKey: "id") }
                        else { $0.fields["id"] = .string(v) }
                    }
                }

            case "list":
                Toggle("Numbered", isOn: Binding(
                    get: { { if case .bool(true) = block.fields["ordered"] { return true }
                             return false }() },
                    set: { v in write(p, si, bi) {
                        if v { $0.fields["ordered"] = .bool(true) }
                        else { $0.fields.removeValue(forKey: "ordered") }
                    } }))
                    .toggleStyle(.checkbox)
                lines("One item per line", block.fields["items"]?.stringList ?? []) { v in
                    write(p, si, bi) { $0.fields["items"] = .array(v.map { .string($0) }) }
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
                ImageBlockEditor(model: model, page: p, si: si, bi: bi, block: block,
                                 site: site)
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

            /* Die Parameter eines Werkzeugs. Das ist die Stelle, an der
               sich seine Logik justieren laesst, ohne den Code
               anzufassen: die Werkzeuge lesen genau diese Attribute. */
            let params = block.fields["params"]?.objectValue ?? [:]
            if !params.isEmpty {
                Text("PARAMETERS")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                    .foregroundColor(.textSecondary)
                ForEach(params.keys.sorted(), id: \.self) { k in
                    field(k, params[k]?.stringValue ?? "") { v in
                        write(p, si, bi) {
                            var o = $0.fields["params"]?.objectValue ?? [:]
                            o[k] = .string(v)
                            $0.fields["params"] = .object(o)
                        }
                    }
                }
            }
            if let inner = block.fields["inner"]?.stringValue, !inner.isEmpty {
                /* Der Inhalt des Containers geht woertlich hinaus. Er wird
                   hier gezeigt, damit man weiss, dass er da ist, und nicht
                   bearbeitet, weil dieser Editor ihn nicht versteht. */
                Text("The container holds \(inner.count) characters of markup, "
                     + "written back unchanged.")
                    .font(.system(size: 10)).foregroundColor(.textSecondary)
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


/*  Das Bild in einem Block
 *  ═══════════════════════════════════════════════════════════════════
 *  Eine Datei aussuchen oder hineinziehen, und die App macht den Rest:
 *  verkleinern auf hoechstens 2000 Pixel Breite, neu kodieren unter 500
 *  Kilobyte, ins Repo legen, Pfad und Maße in den Block schreiben.
 *
 *  Die Maße sind der Grund, warum das nicht nur ein Textfeld sein kann.
 *  Ein img ohne width und height laesst die Seite springen, sobald das
 *  Bild nachlaedt, und zwar genau in dem Moment, in dem jemand zu lesen
 *  angefangen hat. Von Hand eingetippt waeren sie frueher oder spaeter
 *  falsch; gemessen sind sie es nie.
 *
 *  Alt-Text und Credit werden verlangt, nicht empfohlen. Ein Bild ohne
 *  Alt-Text existiert fuer einen Teil der Leser nicht, und ein Bild ohne
 *  Herkunft hat auf diesem Schreibtisch nichts verloren. Beides steht als
 *  Befund am Block, solange es fehlt.
 */
private struct ImageBlockEditor: View {
    @ObservedObject var model: WorkspaceModel
    let page: SitePage
    let si: Int
    let bi: Int
    let block: PageBlock
    let site: SiteProject
    @State private var note: String?

    private var src: String { block.fields["src"]?.stringValue ?? "" }
    private var alt: String { block.fields["alt"]?.stringValue ?? "" }
    private var credit: String { block.fields["credit"]?.stringValue ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dropZone

            if let err = model.imageUploadError {
                Text(err)
                    .font(.system(size: 11)).foregroundColor(.statusRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10)).foregroundColor(.textSecondary)
            }

            field("File in the repo", src) { set("src", $0) }
            HStack(spacing: 10) {
                field("Width", block.fields["width"].map { numberText($0) } ?? "") {
                    set("width", $0)
                }
                field("Height", block.fields["height"].map { numberText($0) } ?? "") {
                    set("height", $0)
                }
            }
            field("Alt text, what the image shows", alt) { set("alt", $0) }
            field("Caption", block.fields["caption"]?.stringValue ?? "") { set("caption", $0) }
            field("Credit and licence", credit) { set("credit", $0) }

            if alt.trimmingCharacters(in: .whitespaces).isEmpty {
                requirement("No alt text. The image is not there at all for a reader using "
                            + "a screen reader, and the page will not say why.")
            }
            if credit.trimmingCharacters(in: .whitespaces).isEmpty {
                requirement("No credit line. Every image on this site carries where it came "
                            + "from and under what licence.")
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            if model.imageUploading {
                ProgressView().controlSize(.small)
                Text("Preparing and uploading").font(.system(size: 12))
                    .foregroundColor(.textSecondary)
            } else {
                Button("Choose an image…") { pick() }
                    .buttonStyle(.bordered)
                Text("or drop one here")
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 2).fill(Color.bgPage))
        .overlay(RoundedRectangle(cornerRadius: 2)
            .stroke(Color.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await accept(url) }
            }
            return true
        }
    }

    private func requirement(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundColor(.statusAmber)
            Text(text)
                .font(.system(size: 10)).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use this image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await accept(url) }
    }

    @MainActor private func accept(_ url: URL) async {
        note = nil
        guard let up = await model.uploadImage(from: url,
                                               folder: "pages/" + page.id) else { return }
        var b = block
        b.fields["src"] = .string(up.src)
        b.fields["width"] = .number(Double(up.width))
        b.fields["height"] = .number(Double(up.height))
        var pg = page
        pg.sections[si].blocks[bi] = b
        model.updatePage(pg)
        let before = up.originalBytes / 1024
        let after = up.finalBytes / 1024
        note = "\(up.width) by \(up.height) pixels, \(before) KB became \(after) KB. "
             + "Not saved yet: the page file goes back with Save."
    }

    private func set(_ key: String, _ value: String) {
        var b = block
        if key == "width" || key == "height" {
            if let n = Double(value.trimmingCharacters(in: .whitespaces)) {
                b.fields[key] = .number(n)
            } else if value.isEmpty {
                b.fields.removeValue(forKey: key)
            } else {
                return   // Buchstaben in einem Maß werden nicht uebernommen.
            }
        } else {
            b.fields[key] = .string(value)
        }
        var pg = page
        pg.sections[si].blocks[bi] = b
        model.updatePage(pg)
    }

    private func numberText(_ v: JSONValue) -> String {
        if case .number(let d) = v { return String(Int(d)) }
        return v.stringValue ?? ""
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
}


/*  Die Vorschau
 *  ═══════════════════════════════════════════════════════════════════
 *  Bis hierher war die Schleife Minuten lang: aendern, speichern, auf
 *  Netlify warten, nachsehen. Jetzt steht das Ergebnis daneben, gerendert
 *  mit BlockRenderer, das heisst mit denselben Regeln wie der Deploy.
 *  Dass "dieselben" nicht bloss "aehnliche" heisst, prueft
 *  `--rendercheck` gegen alle Seiten des echten Repos.
 *
 *  Das Stylesheet kommt aus dem Repo, nicht aus einer Kopie hier. Eine
 *  Vorschau mit eigener Kopie waere genau so lange richtig, bis jemand die
 *  Website anfasst.
 *
 *  Die Grundadresse zeigt auf die Website, damit Schriften und Bilder mit
 *  relativem Pfad sich aufloesen. Sind sie nicht erreichbar, faellt die
 *  Vorschau auf Systemschriften zurueck. Sie zeigt dann das Layout und
 *  nicht die Typografie, und sagt das auch.
 */
private struct PagePreview: View {
    @ObservedObject var model: WorkspaceModel
    let page: SitePage
    let site: SiteProject
    @Environment(\.colorScheme) private var scheme
    @State private var webView = WKWebView()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.designLoading {
                    ProgressView().controlSize(.small)
                    Text("Fetching the stylesheet").font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                } else if model.design == nil {
                    Text("Without the stylesheet this shows the structure, not the design.")
                        .font(.system(size: 11)).foregroundColor(.statusAmber)
                    Button("Fetch it") { Task { await model.loadDesign() } }
                        .buttonStyle(.plain).foregroundColor(.accentNavy)
                        .font(.system(size: 11))
                } else {
                    Text("Rendered with the same rules as the deploy, "
                         + "and the site's own stylesheet.")
                        .font(.system(size: 11)).foregroundColor(.textSecondary)
                }
                Spacer()
            }
            WebViewRepresentable(webView: webView)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.cardBorder, lineWidth: 1))
        }
        .task(id: reloadKey) { render() }
    }

    /// Neu zeichnen, wenn sich Inhalt, Stylesheet oder Theme aendert.
    private var reloadKey: String {
        (try? page.encoded()).map { String($0.hashValue) } ?? page.id
            + (model.design == nil ? "-nocss" : "-css")
            + (scheme == .dark ? "-d" : "-l")
    }

    private func render() {
        let css = model.design.map { sheet in
            /* Der ungeaenderte Stand aus dem Repo plus alles, was im
               Design-Bereich gerade offen ist. So zeigt die Vorschau auch
               eine noch nicht gespeicherte Farbe. */
            sheet.rendered()
        } ?? ""
        let theme = scheme == .dark ? "dark" : "light"
        let html = """
        <!doctype html>
        <html lang="en" data-theme="\(theme)">
        <head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style>
        <style>
          /* Nur fuer die Vorschau: der Rumpf steht hier ohne Kopf und Fuss,
             also braucht er den Rand, den sonst die Seite gibt. */
          body { margin: 0; }
          main { max-width: none; }
        </style>
        </head>
        <body>
        <main class="container" style="padding:1.6rem 1.25rem 3rem;">
          <div class="dd-wrap">
        \(BlockRenderer.body(page))
          </div>
        </main>
        </body></html>
        """
        let base = site.url.flatMap { URL(string: $0) }
        webView.loadHTMLString(html, baseURL: base)
    }
}
