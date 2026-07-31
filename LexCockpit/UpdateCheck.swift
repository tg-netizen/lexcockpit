import Foundation
import SwiftUI
import AppKit

/// The app's version: from the bundle when running as LexCockpit.app,
/// falling back to this constant under bare `swift run`.
enum AppVersion {
    static let fallback = "0.23.0"
    /// Release channel label shown in the UI (badge on Home, Settings
    /// footer). Purely cosmetic — the updater compares bare numbers.
    static let channel = "Beta"
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallback
    }
    static var display: String { "\(current) · \(channel)" }
}

/// Checks the public GitHub Releases API on launch (no token needed) and
/// exposes a subtle "new version" banner. No auto-update, no Sparkle.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var available: (version: String, url: URL)?
    @Published var dismissed = false

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    enum Phase: Equatable { case idle, downloading, installing, failed(String) }
    @Published var phase: Phase = .idle
    @Published var zipURL: URL?          // release asset, when present

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
            zipURL = release.assets?
                .first { $0.name.hasSuffix(".zip") }
                .flatMap { URL(string: $0.browser_download_url) }
        }
    }

    /// True when we're running from a real .app bundle we can replace.
    var canSelfInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && zipURL != nil
    }

    /// One-click update: download the release zip, swap the bundle, relaunch.
    func installUpdate() async {
        guard canSelfInstall, let zip = zipURL else { return }
        phase = .downloading
        do {
            let (tmpZip, _) = try await URLSession.shared.download(from: zip)
            phase = .installing
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("lc-update-\(Int.random(in: 0..<99999))", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", tmpZip.path, stage.path]
            try unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let newApp = try FileManager.default.contentsOfDirectory(
                      at: stage, includingPropertiesForKeys: nil)
                      .first(where: { $0.pathExtension == "app" })
            else { throw APIError.http(0, "no .app in release zip") }

            let current = Bundle.main.bundleURL
            let backup = stage.appendingPathComponent("previous.app")
            try FileManager.default.moveItem(at: current, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: current)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: current)   // roll back
                throw error
            }

            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            try await NSWorkspace.shared.openApplication(at: current, configuration: config)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
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
                switch checker.phase {
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.callout).foregroundColor(.textSecondary)
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Installing — the app will relaunch…").font(.callout).foregroundColor(.textSecondary)
                case .failed(let msg):
                    Text("Update failed: \(msg)").font(.caption).foregroundColor(.statusRed).lineLimit(1)
                    Link("Download manually", destination: update.url)
                        .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                case .idle:
                    if checker.canSelfInstall {
                        Button("Install & relaunch") {
                            Task { await checker.installUpdate() }
                        }
                        .buttonStyle(.borderedProminent).tint(.accentNavy).controlSize(.small)
                    }
                    Link("Release notes", destination: update.url)
                        .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                }
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
