import Foundation
import SwiftUI

/// The app's version: from the bundle when running as LexCockpit.app,
/// falling back to this constant under bare `swift run`.
enum AppVersion {
    static let fallback = "0.2.0"
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallback
    }
}

/// Checks the public GitHub Releases API on launch (no token needed) and
/// exposes a subtle "new version" banner. No auto-update, no Sparkle.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var available: (version: String, url: URL)?
    @Published var dismissed = false

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }

    func check(repo: String = "tg-netizen/lexcockpit") async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LexCockpit", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let releaseURL = URL(string: release.html_url) else { return }   // no releases yet → stay quiet

        let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        if Self.isNewer(remote, than: AppVersion.current) {
            available = (remote, releaseURL)
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let update = checker.available, !checker.dismissed {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundColor(.accentNavy)
                Text("Version \(update.version) available")
                    .font(.callout).foregroundColor(.textPrimary)
                Link("Download", destination: update.url)
                    .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                Spacer()
                Button {
                    checker.dismissed = true
                } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundColor(.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.navyTint)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.cardBorder), alignment: .bottom)
        }
    }
}
