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

    /// Markdown/HTML emitted at the cursor. Blank lines around HTML blocks
    /// keep CommonMark treating them as raw blocks (round-trip safe).
    var markdown: String {
        switch self {
        case .pullquote:
            return "\n<div class=\"pull-quote\">Your pull quote here.</div>\n"
        case .calloutInfo:
            return "\n<div class=\"callout callout--info\">\n<p>Good to know: …</p>\n</div>\n"
        case .calloutWarn:
            return "\n<div class=\"callout callout--warn\">\n<p>Watch out: …</p>\n</div>\n"
        case .figure:
            return "\n<figure>\n<img src=\"/assets/images/articles/…\" alt=\"\">\n<figcaption>Caption.</figcaption>\n</figure>\n"
        case .keyfacts:
            return "\n<div class=\"keyfacts\">\n<p><strong>Key facts</strong></p>\n<ul>\n<li>Fact one</li>\n<li>Fact two</li>\n</ul>\n</div>\n"
        case .divider:
            return "\n---\n"
        }
    }

    /// Payload injected into the editor shell for the slash menu.
    static var jsPayload: String {
        let items = allCases.map { ["label": $0.title, "md": $0.markdown] }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
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
