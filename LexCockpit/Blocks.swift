import SwiftUI
import AppKit

// MARK: - Article blocks (markup the site already styles where possible)

/// Site-CSS audit (style.css): `.pull-quote` EXISTS (gold border, serif
/// italic) → we emit exactly that. `.callout*`, `.keyfacts` and
/// figure/figcaption styling do NOT exist site-side yet — the preview shell
/// carries minimal styles and the missing classes are listed in the release
/// report (site CSS is a separate follow-up; this task never commits there).
enum BlockKind: String, CaseIterable, Identifiable {
    case pullquote, calloutInfo, calloutWarn, figure, keyfacts, divider
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pullquote:   return "Pull quote"
        case .calloutInfo: return "Callout — info"
        case .calloutWarn: return "Callout — warning"
        case .figure:      return "Figure + caption"
        case .keyfacts:    return "Key facts box"
        case .divider:     return "Divider"
        }
    }

    var icon: String {
        switch self {
        case .pullquote:   return "quote.opening"
        case .calloutInfo: return "info.circle"
        case .calloutWarn: return "exclamationmark.triangle"
        case .figure:      return "photo.on.rectangle"
        case .keyfacts:    return "list.bullet.rectangle"
        case .divider:     return "minus"
        }
    }

    /// Markdown/HTML emitted at the cursor. BLANK lines around the blocks are
    /// essential: with a single newline Toast treats the insertion as inline
    /// content and backslash-escapes the tags. Blank-line separation makes it
    /// a real HTML block node (and is CommonMark-canonical in the file).
    var markdown: String {
        switch self {
        case .pullquote:
            return "\n\n<div class=\"pull-quote\">Your pull quote here.</div>\n\n"
        case .calloutInfo:
            return "\n\n<div class=\"callout callout--info\">\n<p>Good to know: …</p>\n</div>\n\n"
        case .calloutWarn:
            return "\n\n<div class=\"callout callout--warn\">\n<p>Watch out: …</p>\n</div>\n\n"
        case .figure:
            return "\n\n<figure>\n<img src=\"/assets/images/articles/…\" alt=\"\">\n<figcaption>Caption.</figcaption>\n</figure>\n\n"
        case .keyfacts:
            return "\n\n<div class=\"keyfacts\">\n<p><strong>Key facts</strong></p>\n<ul>\n<li>Fact one</li>\n<li>Fact two</li>\n</ul>\n</div>\n\n"
        case .divider:
            return "\n\n---\n\n"
        }
    }

    /// Short human description shown in the block gallery.
    var desc: String {
        switch self {
        case .pullquote:   return "A lifted sentence with the site's gold border"
        case .calloutInfo: return "Blue info box for context worth knowing"
        case .calloutWarn: return "Amber warning box for caveats"
        case .figure:      return "Pick an image, caption included"
        case .keyfacts:    return "Grey box with a title and bullet facts"
        case .divider:     return "A thin horizontal rule"
        }
    }

    /// Miniature HTML shown inside the gallery card (site-styled, scaled down).
    var previewHTML: String {
        switch self {
        case .pullquote:
            return "<div class=\"pull-quote\">A line worth lifting out.</div>"
        case .calloutInfo:
            return "<div class=\"callout callout--info\"><p>Good to know: context here.</p></div>"
        case .calloutWarn:
            return "<div class=\"callout callout--warn\"><p>Watch out: caveat here.</p></div>"
        case .figure:
            return "<figure><div style=\"height:30px;background:#E3E9F1;border-radius:4px\"></div><figcaption>Caption</figcaption></figure>"
        case .keyfacts:
            return "<div class=\"keyfacts\"><p><strong>Key facts</strong></p><ul><li>Fact one</li><li>Fact two</li></ul></div>"
        case .divider:
            return "<hr style=\"border:none;border-top:1px solid #D1D5DB;margin:14px 0\">"
        }
    }

    /// The figure block opens the native image picker instead of inserting
    /// a broken placeholder path.
    var action: String { self == .figure ? "imagepick" : "insert" }

    /// Payload injected into the editor shell for the "+" block gallery.
    static var jsPayload: String {
        let items = allCases.map {
            ["id": $0.rawValue, "label": $0.title, "desc": $0.desc,
             "preview": $0.previewHTML, "action": $0.action]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

// MARK: - Block vault (byte-safe design blocks in the WYSIWYG canvas)

/// Toast UI's WYSIWYG cannot round-trip multi-line raw-HTML blocks — it
/// collapses them to one line and reorders attributes. The vault makes the
/// canvas safe: before loading, every design block is swapped for a
/// single-line placeholder in Toast's own canonical form (`data-vault` first —
/// verified byte-stable); on every change the placeholder is swapped back for
/// the untouched original. Blocks render fully styled in the canvas, can be
/// selected, moved and deleted — their text is edited via the block editor
/// sheet, never inline (placeholders are contenteditable=false).
enum BlockVault {
    private static let blockPattern = #"^<(div|figure)\b[^>]*>[\s\S]*?</\1>[ \t]*$"#
    private static let placeholderPattern = #"^<(div|figure)[^>]*?data-vault=\"(\d+)\"[^>]*>.*</\1>[ \t]*$"#

    /// Replace each raw design block with its rendered single-line placeholder.
    static func peel(_ body: String) -> (display: String, vault: [String]) {
        guard let re = try? NSRegularExpression(pattern: blockPattern, options: [.anchorsMatchLines]) else {
            return (body, [])
        }
        let ns = body as NSString
        var vault: [String] = []
        var out = ""
        var last = 0
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let original = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += placeholder(for: original, index: vault.count)
            vault.append(original)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, vault)
    }

    /// Swap placeholders back for their untouched originals. Also undoes the
    /// one blockquote normalization Toast applies ("> " for empty quote lines).
    static func restore(_ edited: String, vault: [String]) -> String {
        guard let re = try? NSRegularExpression(pattern: placeholderPattern, options: []) else { return edited }
        var out: [String] = []
        for line in edited.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 2,
               let idx = Int(ns.substring(with: m.range(at: 2))), idx < vault.count {
                out.append(vault[idx])
            } else if line == "> " {
                out.append(">")
            } else if line == "***" {
                // Toast serializes thematic breaks as *** — the site's
                // editorial convention is ---; both render the same <hr>.
                out.append("---")
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Single-line placeholder in Toast's canonical attribute order
    /// (data-vault first), inner HTML flattened for rendering only.
    static func placeholder(for original: String, index: Int) -> String {
        guard let gt = original.firstIndex(of: ">") else { return original }
        let openTag = String(original[original.startIndex...gt])          // "<div class=...>"
        let tag = openTag.hasPrefix("<figure") ? "figure" : "div"
        let attrs = openTag.dropFirst(tag.count + 1).dropLast()           // " class=..." or ""
        guard let closeRange = original.range(of: "</\(tag)>", options: .backwards) else { return original }
        let inner = String(original[original.index(after: gt)..<closeRange.lowerBound])
            .replacingOccurrences(of: "\n", with: " ")
        return "<\(tag) data-vault=\"\(index)\"\(attrs)>\(inner)</\(tag)>"
    }

    /// Replace the vaulted block `index` (nth occurrence of identical text)
    /// inside `body` with `replacement`; empty replacement removes the block.
    static func replace(_ index: Int, in body: String, vault: [String], with replacement: String) -> String {
        guard index < vault.count else { return body }
        let target = vault[index]
        let nth = vault[0..<index].filter { $0 == target }.count
        var searchStart = body.startIndex
        var found = 0
        while let r = body.range(of: target, range: searchStart..<body.endIndex) {
            if found == nth {
                var out = body.replacingCharacters(in: r, with: replacement)
                if replacement.isEmpty {
                    while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
                }
                return out
            }
            found += 1
            searchStart = r.upperBound
        }
        return body
    }

    /// Plain-text insertion marker: survives any WYSIWYG serialization
    /// verbatim (raw HTML inserted via the editor API gets backslash-escaped,
    /// so blocks are placed by marker + Swift-side substitution instead).
    static let insertionMarker = "@@BLOCKINS@@"

    /// Swap the marker paragraph for the real block markup (empty = cancel).
    /// If the marker vanished (user typed over it), append the block instead
    /// so the action never silently does nothing.
    static func substituteMarker(in body: String, with block: String) -> String {
        let core = block.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: String
        if body.contains(insertionMarker) {
            out = body.replacingOccurrences(of: insertionMarker, with: core)
        } else if core.isEmpty {
            return body
        } else {
            out = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + core + "\n"
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }

    /// Human label for the edit sheet.
    static func kindLabel(of original: String) -> String {
        if original.contains("class=\"pull-quote\"") { return "Pull quote" }
        if original.contains("callout--warn") { return "Callout — warning" }
        if original.contains("class=\"callout") { return "Callout — info" }
        if original.contains("class=\"keyfacts\"") { return "Key facts" }
        if original.hasPrefix("<figure") { return "Figure" }
        return "Block"
    }
}

// MARK: - Canva presets

enum CanvaPreset: String, CaseIterable, Identifiable {
    case ogCover, inlineWide, quoteCard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ogCover:    return "OG cover · 1200×630"
        case .inlineWide: return "Inline wide · 1600×900"
        case .quoteCard:  return "Quote card · 1080×1080"
        }
    }
    var size: (w: Int, h: Int) {
        switch self {
        case .ogCover:    return (1200, 630)
        case .inlineWide: return (1600, 900)
        case .quoteCard:  return (1080, 1080)
        }
    }
    var isCover: Bool { self == .ogCover }
    var slugSuffix: String {
        switch self {
        case .ogCover: return "cover"
        case .inlineWide: return "wide"
        case .quoteCard: return "quote"
        }
    }
}

// MARK: - Recent designs picker

struct CanvaDesignItem: Decodable, Identifiable {
    struct Thumb: Decodable { let url: String? }
    struct URLs: Decodable { let edit_url: String? }
    let id: String
    let title: String?
    let thumbnail: Thumb?
    let updated_at: Int?
    let urls: URLs?
}

extension CanvaAPI {
    private struct ListEnvelope: Decodable { let items: [CanvaDesignItem]? }

    static func listDesigns() async throws -> [CanvaDesignItem] {
        let data = try await authorized("/rest/v1/designs?limit=50")
        return (try JSONDecoder().decode(ListEnvelope.self, from: data)).items ?? []
    }
}

/// "From my Canva…" — thumbnail grid of recent designs; select → export →
/// the same import pipeline as everything else.
struct CanvaPickerSheet: View {
    var onPick: (CanvaDesignItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CanvaDesignItem] = []
    @State private var search = ""
    @State private var loading = true
    @State private var errorText: String?

    private var filtered: [CanvaDesignItem] {
        guard !search.isEmpty else { return items }
        let q = search.lowercased()
        return items.filter { ($0.title ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.textSecondary)
                TextField("Search designs…", text: $search).textFieldStyle(.plain)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let err = errorText {
                Spacer(); Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.statusRed).padding(); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { item in
                            Button {
                                onPick(item)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ZStack {
                                        Rectangle().fill(Color.cardBorder)
                                        if let thumb = item.thumbnail?.url, let url = URL(string: thumb) {
                                            AsyncImage(url: url) { phase in
                                                if case .success(let img) = phase {
                                                    img.resizable().aspectRatio(contentMode: .fill)
                                                } else {
                                                    Image(systemName: "photo").foregroundColor(.textSecondary)
                                                }
                                            }
                                        } else {
                                            Image(systemName: "photo").foregroundColor(.textSecondary)
                                        }
                                    }
                                    .frame(height: 110).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(item.title?.isEmpty == false ? item.title! : "Untitled design")
                                        .font(.caption).foregroundColor(.textPrimary).lineLimit(1)
                                    if let ts = item.updated_at {
                                        Text(relativeTime(ISO8601DateFormatter().string(
                                            from: Date(timeIntervalSince1970: TimeInterval(ts)))))
                                            .font(.caption2).foregroundColor(.textSecondary)
                                    }
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 760, height: 540)
        .task {
            do { items = try await CanvaAPI.listDesigns() }
            catch { errorText = error.localizedDescription }
            loading = false
        }
    }
}
