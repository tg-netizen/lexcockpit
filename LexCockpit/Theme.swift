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

/*  The palette is the website's palette
 *  ═══════════════════════════════════════════════════════════════════
 *  Of sixteen colour roles, this app used to share exactly one with
 *  lexdigestglobal.com, and that one was #FFFFFF. That is the whole
 *  reason the two did not read as one house: the eye takes the colour
 *  temperature before it takes anything else, and #FAFAFA is cold while
 *  the site's paper #F7F5F0 is warm.
 *
 *  The light values below are lifted verbatim from assets/css/style.css
 *  in the site repo. The dark values take the site's hues but not all of
 *  its surface distances: a website is one column of text, this is a work
 *  surface with cards inside cards, so it needs a third rung and a line
 *  you can actually see.
 *
 *  Every number was measured, not chosen. Contrast ratios are WCAG 2.1,
 *  computed against the surface the colour actually sits on:
 *
 *    light   textPrimary 18.88   textSecondary 5.28   accent 14.22
 *            goldText 4.91       green 5.19   amber 5.02   red 5.74
 *    dark    textPrimary 11.71   textSecondary 6.26   accent 13.46
 *            goldText 6.95       green 7.06   amber 7.51   red 6.56
 *
 *  Two failures this replaces, both measured on the old palette: white on
 *  accentNavy in dark mode was 2.23, which made the editor's Publish
 *  button unreadable at night, and brandGold as text was 2.01 on white.
 */
extension Color {
    // ── Surfaces ────────────────────────────────────────────────────
    /// The site's paper. Warm, not the cold #FAFAFA this used to be.
    static let bgPage     = dyn("#F7F5F0", "#12141B")
    static let bgCard     = dyn("#FFFFFF", "#1B2030")
    /// A third rung, for a card inside a card. The website has no need
    /// for one; a workspace does, and stacking two identical surfaces
    /// reads as one surface with a stray border.
    static let bgCardRaised = dyn("#F4F2ED", "#262C3D")
    /// The hairline. Dark is deliberately lighter than the site's
    /// #2A3040: at 1.23 against the card that line is a rumour, and this
    /// app leans on borders where the site can lean on whitespace.
    static let cardBorder = dyn("#E0DED8", "#4A5474")

    // ── Ink ─────────────────────────────────────────────────────────
    static let textPrimary   = dyn("#111111", "#D9DBE2")
    static let textSecondary = dyn("#656C7A", "#9AA1B2")

    // ── Accent ──────────────────────────────────────────────────────
    /// What is clickable. In dark mode the site inverts this to near
    /// white, which is why it must never be used as a fill under white
    /// text; use accentNavySolid for that.
    static let accentNavy   = dyn("#1B2A4A", "#E7EAF2")
    /// A navy that stays navy in both themes, for filled buttons and
    /// badges carrying light text. White on it: 14.22 light, 5.19 dark.
    static let accentNavySolid = dyn("#1B2A4A", "#3E6FA8")
    /// The selected row behind a label.
    static let navyTint     = dyn("#EDEAE3", "#2F4166")

    // ── Status ──────────────────────────────────────────────────────
    static let statusGreen  = dyn("#0E7C5A", "#5CBD92")
    static let statusAmber  = dyn("#B45309", "#D9A94E")
    static let statusRed    = dyn("#C81E1E", "#E88B8B")

    // ── Gold ────────────────────────────────────────────────────────
    /// Gold carries one meaning in this project and it is never "click
    /// me": unsaved work. As a fill or a dot only, because at 2.33 on
    /// white it cannot legally carry text.
    static let brandGold  = dyn("#C2A675", "#C2A675")
    /// The site's own readable gold, for the rare case gold must be
    /// text. 4.91 on white, 6.95 on the dark card.
    static let goldText   = dyn("#816E4E", "#C2A675")

    // ── Back-compat aliases ─────────────────────────────────────────
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

/// Big-number stat tile: the number carries the weight (primary ink,
/// tabular digits), the accent lives only in the small icon — the
/// dashboard pattern from the Branch shot (Collect UI research).
struct StatTile: View {
    let value: String
    let label: String
    var accent: Color = .accentNavy
    var icon: String? = nil
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(value)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 5) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(accent)
                    }
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 96)
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

// MARK: - Generic error and empty states

/// A panel that could not load, with the reason kept and a way to try again.
///
/// `FeedErrorCard` above does this for feed failures, which carry a typed
/// `FeedFailure`. Everything else in the app used to hand-roll its own red
/// text, so the same failure looked different in three places and none of
/// them offered a retry. A load that failed and a load that returned
/// nothing are different facts, and the user should be able to tell them
/// apart without reading the code.
struct ErrorCard: View {
    let title: String
    let detail: String
    var retry: (() -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.statusRed)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    if let retry {
                        Button("Try again", action: retry)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.accentNavy)
                    }
                }
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Nothing here, said in a way that tells the user whether that is a
/// finding or just a starting point.
struct EmptyCard: View {
    let title: String
    let detail: String
    var systemImage: String = "tray"

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage).foregroundColor(.textSecondary)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
