import SwiftUI

// Brand palette (matches lexdigestglobal.com)
extension Color {
    static let brandNavy  = Color(red: 0.122, green: 0.165, blue: 0.267) // #1F2A44
    static let brandGold  = Color(red: 0.788, green: 0.710, blue: 0.549) // #C9B58C
    static let brandCream = Color(red: 0.953, green: 0.941, blue: 0.914) // #F3F0E9
    static let brandInk   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let stApplied  = Color(red: 0.114, green: 0.357, blue: 0.204)
    static let stUpcoming = Color(red: 0.478, green: 0.396, blue: 0.157)
    static let stBlocked  = Color(red: 0.627, green: 0.125, blue: 0.125)
}

// A small status pill
struct Pill: View {
    let text: String
    var color: Color = .brandNavy
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
    case .applied:  return Pill(text: status.rawValue, color: .stApplied)
    case .upcoming: return Pill(text: status.rawValue, color: .stUpcoming)
    case .blocked:  return Pill(text: status.rawValue, color: .stBlocked)
    }
}

func projectPill(_ status: String?) -> Pill {
    switch (status ?? "").lowercased() {
    case "published": return Pill(text: "Published", color: .stApplied)
    case "scheduled": return Pill(text: "Scheduled", color: .stUpcoming)
    case "draft":     return Pill(text: "Draft", color: .brandNavy)
    default:          return Pill(text: status ?? "—", color: .secondary)
    }
}

// A reusable card container
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

// A section header used at the top of each detail view
struct DetailHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .foregroundColor(.brandNavy)
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }
}

// A compact KPI tile for the dashboard
struct StatTile: View {
    let value: String
    let label: String
    var accent: Color = .brandNavy
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundColor(accent)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.secondary)
            }
        }
    }
}
