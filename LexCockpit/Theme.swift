import SwiftUI
import AppKit

// MARK: - Semantic palette (light-first, dark-capable)
//
// The LexDigest Pro workspace look: near-white window, white cards with a
// hairline border, navy accents, muted status colors. No hardcoded
// appearance — every color is a dynamic NSColor so system dark mode reads
// correctly too.

private func hex(_ s: String) -> NSColor {
    var v = UInt64(0)
    Scanner(string: String(s.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private func dyn(_ light: String, _ dark: String) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
    })
}

extension Color {
    // Surfaces
    static let bgPage     = dyn("#FAFAFA", "#1C1C1E")   // window background
    static let bgCard     = dyn("#FFFFFF", "#28282A")   // cards + sidebar
    static let cardBorder = dyn("#E5E7EB", "#3C3C40")   // 1px hairlines

    // Ink
    static let textPrimary   = dyn("#111827", "#F2F2F4")
    static let textSecondary = dyn("#6B7280", "#A2A2AA")

    // Accent + status (muted, per the Pro reference)
    static let accentNavy   = dyn("#1F3A5F", "#8FB0DC")
    static let navyTint     = dyn("#EDF1F7", "#2E3A4C")  // active sidebar row
    static let statusGreen  = dyn("#2F7D5B", "#5CBD92")
    static let statusAmber  = dyn("#9C6B1E", "#D9A94E")
    static let statusRed    = dyn("#A83232", "#E07272")

    // Small warm accent (dirty dots, gold pills) — kept from the site brand
    static let brandGold  = dyn("#C9B58C", "#C9B58C")

    // Back-compat aliases so existing views pick up the new system wholesale
    static let brandNavy  = accentNavy
    static let brandCream = bgPage
    static let brandInk   = textPrimary
    static let stApplied  = statusGreen
    static let stUpcoming = statusAmber
    static let stBlocked  = statusRed
}

// MARK: - Pills

struct Pill: View {
    let text: String
    var color: Color = .accentNavy
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

func pill(for status: RegStatus) -> Pill {
    switch status {
    case .applied:  return Pill(text: status.rawValue, color: .statusGreen)
    case .upcoming: return Pill(text: status.rawValue, color: .statusAmber)
    case .blocked:  return Pill(text: status.rawValue, color: .statusRed)
    }
}

func projectPill(_ status: String?) -> Pill {
    switch (status ?? "").lowercased() {
    case "published": return Pill(text: "Published", color: .statusGreen)
    case "scheduled": return Pill(text: "Scheduled", color: .statusAmber)
    case "draft":     return Pill(text: "Draft", color: .accentNavy)
    default:          return Pill(text: status ?? "—", color: .textSecondary)
    }
}

// MARK: - Card

/// White card, 1px hairline, 8px radius, very subtle shadow — the Pro look.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.bgCard)
                    .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }
}

// MARK: - Page header

struct DetailHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.textPrimary)
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.textSecondary)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - KPI tile

/// White card, big navy number, uppercase gray label — like Pro's KPI tiles.
struct StatTile: View {
    let value: String
    let label: String
    var accent: Color = .accentNavy
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(accent)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 86)
    }
}

// MARK: - Feed error card (per-section, expandable debug detail)

struct FeedErrorCard: View {
    let title: String
    let failure: FeedFailure
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.statusRed)
                        Text("\(title): \(failure.summary)")
                            .fontWeight(.medium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                    if expanded {
                        Text(failure.detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
