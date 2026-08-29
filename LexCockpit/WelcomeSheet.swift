import SwiftUI
import AppKit

/// Welcome / What's-new window — the Branch-onboarding pattern from the
/// Collect UI research: a deliberately dark navy card (both themes),
/// centered app icon + serif title, one bright button, and small mosaic
/// tiles in the corners carrying REAL facts about this install.
///
/// Shows once per version: first launch ever → "Welcome", after an
/// update → "What's new". `lastSeenVersion` in UserDefaults gates it;
/// the token-onboarding sheet always wins the first launch.
struct WelcomeSheet: View {
    @EnvironmentObject var store: CockpitStore
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool

    // Fixed dark palette — this card looks the same in light and dark.
    private let cardBG   = Color(red: 0.075, green: 0.11, blue: 0.185)
    private let tileBG   = Color.white.opacity(0.07)
    private let inkSoft  = Color.white.opacity(0.62)

    /// Real highlights of the current beta line — update per release.
    private let highlights = [
        "Check for Updates in Settings → About — install & relaunch in one click",
        "Free news waiting list from Supabase (Settings → Ingest)",
        "Overview shows scanned RSS hits scored for LexDigestGlobal",
        "Content library Review filter for AI drafts",
        "Library and ⌘K grouped by Today / Yesterday / Earlier"
    ]

    var body: some View {
        ZStack {
            cardBG
            VStack(spacing: 18) {
                Spacer(minLength: 26)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)

                Text(firstRun ? "Welcome to LexCockpit"
                              : "What's new in \(AppVersion.current)")
                    .font(.system(size: 27, weight: .bold, design: .serif))
                    .foregroundColor(.white)

                if firstRun {
                    Text("Your editorial cockpit for LexDigestGlobal —\nwrite, plan, publish, and watch the data feeds.")
                        .font(.system(size: 13))
                        .foregroundColor(inkSoft)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(highlights, id: \.self) { h in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Color.brandGold).frame(width: 5, height: 5)
                                    .padding(.top, 5)
                                Text(h).font(.system(size: 12.5)).foregroundColor(inkSoft)
                            }
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                }

                Button(firstRun ? "Get started" : "Continue") { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 26).padding(.vertical, 9)
                    .background(Capsule().fill(Color.white))
                    .keyboardShortcut(.defaultAction)

                if let url = URL(string: "https://github.com/tg-netizen/lexcockpit/releases") {
                    Link("Release notes", destination: url)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(inkSoft)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 40)
        }
        .overlay(alignment: .topLeading)     { tile("\(store.sites.count) PROJECT\(store.sites.count == 1 ? "" : "S")").padding(14) }
        .overlay(alignment: .topTrailing)    { tile("\(AppFacts.selftests) SELFTESTS\nGREEN").padding(14) }
        .overlay(alignment: .bottomLeading)  { tile("AUTO-DATA\nMON + THU").padding(14) }
        .overlay(alignment: .bottomTrailing) { tile("BLOCK VAULT\nBYTE-SAFE").padding(14) }
        .frame(width: 620, height: 470)
        .onDisappear { markSeen() }
    }

    private func tile(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(inkSoft)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(tileBG))
    }

    private func close() { markSeen(); dismiss() }
    private func markSeen() {
        UserDefaults.standard.set(AppVersion.current, forKey: "lastSeenVersion")
    }
}


/*  Zahlen ueber die App selbst
 *  ═══════════════════════════════════════════════════════════════════
 *  Auf diesem Schirm stand "54 SELFTESTS GREEN", waehrend es 191 waren.
 *  Eine falsche Zahl auf dem Begruessungsschirm einer App, deren Zweck
 *  das Pruefen von Behauptungen ist, ist der teuerste kleine Fehler im
 *  Projekt: sie lehrt den Nutzer, den Zahlen hier nicht zu glauben.
 *
 *  Der Wert steht deshalb nicht mehr im Text, sondern hier, und der
 *  Selbsttest prueft ihn gegen die Zahl, die er selbst gezaehlt hat. Wer
 *  einen Test hinzufuegt und die Zahl vergisst, bekommt einen roten
 *  Testlauf, keinen stillen Irrtum. Die Zahl kann nur noch falsch sein,
 *  wenn jemand sie absichtlich falsch macht.
 */
enum AppFacts {
    /// Genau die Anzahl der PASS-Zeilen von `--selftest`, also das, was
    /// `swift run LexCockpit --selftest | grep -c PASS` ausgibt. Der
    /// Selbsttest setzt das durch und schlaegt fehl, wenn es nicht stimmt.
    static let selftests = 217
}
