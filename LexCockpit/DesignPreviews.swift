#if DEBUG
import SwiftUI

// ═══════════════════════════════════════════════════════════════
// Design playground — Xcode canvas only (never ships: #if DEBUG).
//
// Open this file in Xcode and show the canvas (Editor → Canvas,
// ⌥⌘↩): every #Preview below renders live. Change a number or a
// hex value anywhere in the app and the canvas follows instantly —
// this is the "design in Xcode" surface for LexCockpit.
// ═══════════════════════════════════════════════════════════════

private struct Swatch: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 44, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cardBorder, lineWidth: 1))
            Text(name).font(.system(size: 12, design: .monospaced)).foregroundColor(.textPrimary)
            Spacer()
        }
    }
}

#Preview("Farben — Design-Token") {
    VStack(alignment: .leading, spacing: 8) {
        Text("SEMANTIC COLORS").font(.system(size: 11, weight: .semibold)).tracking(0.7)
            .foregroundColor(.textSecondary)
        Swatch(name: "bgPage",        color: .bgPage)
        Swatch(name: "bgCard",        color: .bgCard)
        Swatch(name: "cardBorder",    color: .cardBorder)
        Swatch(name: "textPrimary",   color: .textPrimary)
        Swatch(name: "textSecondary", color: .textSecondary)
        Swatch(name: "accentNavy",    color: .accentNavy)
        Swatch(name: "navyTint",      color: .navyTint)
        Swatch(name: "statusGreen",   color: .statusGreen)
        Swatch(name: "statusAmber",   color: .statusAmber)
        Swatch(name: "statusRed",     color: .statusRed)
        Swatch(name: "brandGold",     color: .brandGold)
    }
    .padding(24)
    .frame(width: 320)
    .background(Color.bgPage)
}

#Preview("Typografie — Größenrampe") {
    VStack(alignment: .leading, spacing: 14) {
        Text("Good afternoon").font(.system(size: 28, weight: .bold))
            .foregroundColor(.textPrimary)
        Text("Section header — 16 semibold").font(.system(size: 16, weight: .semibold))
            .foregroundColor(.textPrimary)
        Text("Body copy — 14 regular. The quick brown fox jumps over the lazy dog.")
            .font(.system(size: 14)).foregroundColor(.textPrimary)
        Text("Secondary — 12 regular, textSecondary").font(.system(size: 12))
            .foregroundColor(.textSecondary)
        Text("EYEBROW LABEL — 11 SEMIBOLD, TRACKING 0.7")
            .font(.system(size: 11, weight: .semibold)).tracking(0.7)
            .foregroundColor(.textSecondary)
    }
    .padding(24)
    .frame(width: 420, alignment: .leading)
    .background(Color.bgPage)
}

#Preview("Stat-Kacheln (Branch-Stil)") {
    HStack(spacing: 14) {
        StatTile(value: "12", label: "Published", accent: .stApplied, icon: "checkmark.circle")
        StatTile(value: "3", label: "Scheduled", accent: .brandGold, icon: "calendar")
        StatTile(value: "14.2k", label: "Words written", accent: .accentNavy, icon: "text.alignleft")
    }
    .padding(24)
    .frame(width: 560)
    .background(Color.bgPage)
}

#Preview("Beta-Badge") {
    VStack(spacing: 16) {
        HStack(spacing: 10) {
            Text("Good afternoon").font(.system(size: 28, weight: .bold))
                .foregroundColor(.textPrimary)
            BetaBadge()
        }
        BetaBadge()
    }
    .padding(24)
    .background(Color.bgPage)
}

private struct UpdateBannerPreviewHost: View {
    @ObservedObject private var checker = UpdateChecker.shared
    var body: some View {
        UpdateBanner(checker: checker)
            .onAppear {
                checker.available = ("0.19.0", URL(string: "https://github.com/tg-netizen/lexcockpit/releases")!)
            }
    }
}

#Preview("Update-Banner") {
    UpdateBannerPreviewHost()
        .frame(width: 560)
        .background(Color.bgPage)
}
#endif
