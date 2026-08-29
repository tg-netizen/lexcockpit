import Foundation
import SwiftUI
import AppKit

/// The app's version: from the bundle when running as LexCockpit.app,
/// falling back to this constant under bare `swift run`.
enum AppVersion {
    static let fallback = "0.33.0"
    /// Release channel label shown in the UI (badge on Home, Settings
    /// footer). Purely cosmetic — the updater compares bare numbers.
    static let channel = "Beta"
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallback
    }
    static var display: String { "\(current) · \(channel)" }
}

/// Checks the public GitHub Releases API (no token needed).
/// Shared so the banner, Settings → About, and the app menu stay in sync.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var available: (version: String, url: URL)?
    @Published var dismissed = false
    @Published var checking = false
    @Published var upToDate = false
    @Published var lastError: String?
    @Published var lastChecked: Date?

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
    @Published var zipURL: URL?

    /// Silent launch check. `force` = user clicked "Check for Updates".
    func check(repo: String = "tg-netizen/lexcockpit", force: Bool = false) async {
        if force {
            dismissed = false
            upToDate = false
            lastError = nil
            available = nil
            zipURL = nil
            phase = .idle
        }
        checking = true
        defer { checking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LexCockpit", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                lastError = "GitHub returned HTTP \(code)"
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.draft != true, release.prerelease != true,
                  let releaseURL = URL(string: release.html_url) else {
                if force { lastError = "No published release yet." }
                return
            }

            let remote = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst()) : release.tag_name
            lastChecked = Date()
            if Self.isNewer(remote, than: AppVersion.current) {
                available = (remote, releaseURL)
                zipURL = release.assets?
                    .first { $0.name.hasSuffix(".zip") }
                    .flatMap { URL(string: $0.browser_download_url) }
                upToDate = false
            } else {
                available = nil
                zipURL = nil
                upToDate = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// True when we're running from a real .app bundle we can replace.
    var canSelfInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && zipURL != nil
    }

    /// Run a tool and hand back (exit status, combined output).
    private static func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /**
     Refuse to install a bundle whose code signature does not check out.

     Without this the updater downloaded a zip, unpacked it and replaced the
     running app with whatever was inside — no signature check, no checksum, no
     identity pinning. Three details made that worse than it sounds: the release
     bundle is ad-hoc signed with no Team ID, `URLSession` downloads carry no
     quarantine attribute so Gatekeeper never evaluates the result, and the app
     is self-signed anyway. Anyone able to publish a release asset on the repo
     could run code on this machine.

     `codesign --verify --strict` is the floor, not the ceiling: it proves the
     bundle is internally consistent and unmodified since signing, not WHO
     signed it. An ad-hoc signature carries no identity to pin, so this is as
     far as it can go until the app has a real Developer ID — at which point a
     `--requirement` on the team identifier belongs here too.
     */
    private static func verifySignature(of app: URL) throws {
        let (status, output) = try run("/usr/bin/codesign",
                                       ["--verify", "--strict", "--deep", app.path])
        guard status == 0 else {
            let detail = output.split(separator: "\n").first.map(String.init)
                ?? "invalid signature"
            throw APIError.http(0, "update rejected — signature check failed: \(detail)")
        }
    }

    /// One-click update: download the release zip, swap the bundle, relaunch.
    func installUpdate() async {
        guard canSelfInstall, let zip = zipURL else {
            if let url = available?.url {
                NSWorkspace.shared.open(url)
            }
            return
        }
        phase = .downloading
        /* A fresh directory every time. The old name came from
           `Int.random(in: 0..<99999)` and was created with
           `withIntermediateDirectories: true`, which does NOT throw when the
           directory already exists — so a collision silently reused a staging
           directory that could still hold `previous.app` from a failed attempt.
           `contentsOfDirectory` has no defined order, so the installer could
           then have picked the OLD bundle and reported success. */
        let stage = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lc-update-\(UUID().uuidString)", isDirectory: true)

        do {
            let (tmpZip, _) = try await URLSession.shared.download(from: zip)
            phase = .installing
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

            let unpack = stage.appendingPathComponent("unpack", isDirectory: true)
            try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
            let (unzipStatus, unzipOut) = try Self.run("/usr/bin/ditto",
                                                       ["-xk", tmpZip.path, unpack.path])
            guard unzipStatus == 0 else {
                throw APIError.http(0, "could not unpack the release zip: \(unzipOut)")
            }
            /* Exactly one .app, or refuse. "Take the first one you find" is not
               a decision an updater should make on the user's behalf. */
            let apps = try FileManager.default
                .contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let newApp = apps.first else {
                throw APIError.http(0, apps.isEmpty
                    ? "no .app in the release zip"
                    : "release zip contains \(apps.count) apps — refusing to guess")
            }
            try Self.verifySignature(of: newApp)

            let current = Bundle.main.bundleURL
            let backup = stage.appendingPathComponent("previous.app")
            try FileManager.default.moveItem(at: current, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: current)
            } catch {
                /* If putting the new bundle in place fails, the old one is
                   already gone. A silent `try?` here meant a failed rollback
                   left the user with no app at all and nothing saying so. */
                do {
                    try FileManager.default.moveItem(at: backup, to: current)
                } catch {
                    throw APIError.http(0, "update failed and the previous version "
                        + "could not be restored automatically. A copy is at "
                        + "\(backup.path) — move it back to \(current.path).")
                }
                throw error
            }
            /* Verify the installed copy too: `ditto -xk` restores whatever
               attributes the archive carried, and a bundle that fails
               validation in place will not launch. Checking before handing
               control over means a rollback is still possible. */
            do {
                try Self.verifySignature(of: current)
            } catch {
                try? FileManager.default.removeItem(at: current)
                try? FileManager.default.moveItem(at: backup, to: current)
                throw error
            }

            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            try await NSWorkspace.shared.openApplication(at: current, configuration: config)
            /* Only now is the staging copy expendable. */
            try? FileManager.default.removeItem(at: stage)
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: stage)
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

// MARK: - Top banner (auto-shown when a newer release exists)

struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let update = checker.available, !checker.dismissed {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundColor(.accentNavy)
                Text("Version \(update.version) available")
                    .font(.callout).foregroundColor(.textPrimary)
                UpdateActionButtons(checker: checker, compact: true)
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

// MARK: - Settings / About panel + reusable actions

struct UpdatePanel: View {
    @ObservedObject var checker: UpdateChecker = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.callout.weight(.semibold))
            Text("Installed: \(AppVersion.display)")
                .font(.caption).foregroundColor(.textSecondary)

            HStack(spacing: 10) {
                Button {
                    Task { await checker.check(force: true) }
                } label: {
                    if checker.checking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(checker.checking || checker.phase == .downloading || checker.phase == .installing)
                .keyboardShortcut("u", modifiers: [.command, .shift])

                UpdateActionButtons(checker: checker, compact: false)
            }

            statusLine
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
    }

    @ViewBuilder private var statusLine: some View {
        if checker.checking {
            Text("Looking up the latest GitHub release…")
                .font(.caption).foregroundColor(.textSecondary)
        } else if case .failed(let msg) = checker.phase {
            Text("Install failed: \(msg)")
                .font(.caption).foregroundColor(.statusRed)
        } else if let err = checker.lastError {
            Text(err).font(.caption).foregroundColor(.statusRed)
        } else if let update = checker.available {
            Text("Version \(update.version) is ready to install.")
                .font(.caption).foregroundColor(.statusAmber)
            if !checker.canSelfInstall {
                Text("Self-install works from LexCockpit.app (not from `swift run`). Use Download if needed.")
                    .font(.caption2).foregroundColor(.textSecondary)
            }
        } else if checker.upToDate {
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.statusGreen)
        } else if let t = checker.lastChecked {
            Text("Last checked \(t.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundColor(.textSecondary)
        }
    }
}

struct UpdateActionButtons: View {
    @ObservedObject var checker: UpdateChecker
    var compact: Bool

    var body: some View {
        Group {
            switch checker.phase {
            case .downloading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.callout).foregroundColor(.textSecondary)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(compact ? "Installing…" : "Installing — the app will relaunch…")
                        .font(.callout).foregroundColor(.textSecondary)
                }
            case .failed:
                if let url = checker.available?.url {
                    Link("Download manually", destination: url)
                        .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                }
            case .idle:
                if checker.available != nil {
                    if checker.canSelfInstall {
                        Button(compact ? "Install & relaunch" : "Install Update & Relaunch") {
                            Task { await checker.installUpdate() }
                        }
                        .buttonStyle(.borderedProminent).tint(.accentNavySolid)
                        .controlSize(compact ? .small : .regular)
                    } else if let url = checker.available?.url {
                        Link(compact ? "Download" : "Download from GitHub", destination: url)
                            .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                    }
                    if let url = checker.available?.url, !compact {
                        Link("Release notes", destination: url)
                            .font(.caption)
                    } else if let url = checker.available?.url, compact {
                        Link("Release notes", destination: url)
                            .font(.callout.weight(.semibold)).foregroundColor(.accentNavy)
                    }
                }
            }
        }
    }
}
