import SwiftUI
import AppKit

/// App-wide chrome state (focus mode hides sidebar, tab bar and panels).
final class ChromeModel: ObservableObject {
    @Published var focus = false
}

/// Collapsible writing-quality sidebar (⌘I): live counts, SEO meters,
/// an OG share-preview card, and a pre-publish checklist. Warnings only —
/// publishing is never blocked.
struct QualityPanel: View {
    @ObservedObject var doc: EditorDocument
    var coverImage: NSImage?
    var articleURL: String = ""
    @State private var copied: String?

    private var words: Int {
        doc.bodyText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
    private var readingMinutes: Int { max(1, Int((Double(words) / 220.0).rounded(.up))) }
    private var tags: [String] {
        doc.tagsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var leftoverTODO: Bool {
        let lowered = doc.bodyText.lowercased()
        return lowered.contains("todo") || lowered.contains("text will follow") || lowered.contains("text folgt")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    sectionLabel("Text")
                    HStack(spacing: 14) {
                        stat("\(words)", "words")
                        stat("\(readingMinutes) min", "read")
                        stat("\(tags.count)", "tags")
                    }
                }

                Group {
                    sectionLabel("SEO")
                    meter(label: "Title", count: doc.title.count,
                          state: doc.title.isEmpty ? .bad : (doc.title.count <= 65 ? .good : .warn),
                          hint: "≤ 65 characters")
                    meter(label: "Description", count: doc.descriptionText.count,
                          state: doc.descriptionText.isEmpty ? .bad
                                 : (doc.descriptionText.count >= 50 && doc.descriptionText.count <= 160 ? .good : .warn),
                          hint: "50–160 characters")
                }

                Group {
                    sectionLabel("Share preview")
                    ogCard
                }

                Group {
                    sectionLabel("Share")
                    shareButton("LinkedIn post", id: "li", text: linkedInText)
                    shareButton("X post (\(xText.count)/280)", id: "x", text: xText)
                }

                Group {
                    sectionLabel("Before publishing")
                    checkRow(ok: !doc.heroImagePath.isEmpty, text: "Cover image set")
                    checkRow(ok: !doc.descriptionText.isEmpty, text: "Description present")
                    checkRow(ok: !tags.isEmpty, text: "At least one tag")
                    checkRow(ok: !leftoverTODO, text: "No TODO / placeholder text left")
                    Text("Warnings only — publishing is never blocked.")
                        .font(.caption2).foregroundColor(.textSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bgPage)
    }

    // MARK: pieces

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundColor(.textSecondary)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(.accentNavy)
            Text(label).font(.caption2).foregroundColor(.textSecondary)
        }
    }

    private enum MeterState { case good, warn, bad
        var color: Color {
            switch self {
            case .good: return .statusGreen
            case .warn: return .statusAmber
            case .bad:  return .statusRed
            }
        }
    }

    private func meter(label: String, count: Int, state: MeterState, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(count)").font(.system(.caption, design: .monospaced))
                    .foregroundColor(state.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.cardBorder).frame(height: 4)
                    Capsule().fill(state.color)
                        .frame(width: geo.size.width * min(1, CGFloat(count) / 160), height: 4)
                }
            }
            .frame(height: 4)
            Text(hint).font(.caption2).foregroundColor(.textSecondary)
        }
    }

    /// LinkedIn-style share card rendered from frontmatter data.
    private var ogCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color.cardBorder)
                if let img = coverImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.title3).foregroundColor(.textSecondary)
                }
            }
            .frame(height: 118)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title.isEmpty ? "Untitled article" : doc.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                if !doc.descriptionText.isEmpty {
                    Text(doc.descriptionText)
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }
                Text("lexdigestglobal.com")
                    .font(.system(size: 10)).foregroundColor(.textSecondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    private var hashtags: String {
        tags.prefix(3).map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
    }
    private var linkedInText: String {
        var t = doc.title + "\n\n" + doc.descriptionText
        if !articleURL.isEmpty { t += "\n\n" + articleURL }
        if !hashtags.isEmpty { t += "\n\n" + hashtags }
        return t
    }
    private var xText: String {
        var t = doc.title
        if !doc.descriptionText.isEmpty { t += " — " + doc.descriptionText }
        if t.count > 240 { t = String(t.prefix(237)) + "…" }
        if !articleURL.isEmpty { t += " " + articleURL }
        return t
    }
    private func shareButton(_ label: String, id: String, text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == id { copied = nil } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied == id ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                Text(copied == id ? "Copied!" : label).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(copied == id ? .statusGreen : .accentNavy)
    }

    private func checkRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(ok ? .statusGreen : .statusAmber)
                .font(.system(size: 12))
            Text(text).font(.caption)
                .foregroundColor(ok ? .textSecondary : .textPrimary)
        }
    }
}
