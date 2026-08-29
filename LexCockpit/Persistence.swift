import AppKit
import SwiftUI

// MARK: - Security-scoped bookmark store (never ask twice)

/// Persists user-granted file access as security-scoped bookmarks and
/// re-opens them silently on launch. Works sandboxed or not; stale
/// bookmarks are dropped silently and only re-prompted when actually needed.
enum BookmarkStore {
    static let projectsJSON = "projects-json"

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit", isDirectory: true)
    }
    private static var file: URL { dir.appendingPathComponent("bookmarks.json") }
    private static var accessed: [URL] = []

    private static func loadMap() -> [String: Data] {
        (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))) ?? [:]
    }
    private static func saveMap(_ map: [String: Data]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file) }
    }

    /// Store access to a URL the user just granted via an open panel.
    static func store(_ url: URL, key: String) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var map = loadMap()
        map[key] = data
        saveMap(map)
    }

    /// Ein Lesezeichen vergessen, etwa wenn der Nutzer wieder ueber
    /// GitHub arbeiten will.
    static func forget(_ key: String) {
        var map = loadMap()
        map[key] = nil
        saveMap(map)
    }

    /// Resolve a stored bookmark and begin access. Returns nil (and forgets
    /// the entry) when stale — caller re-prompts only when needed.
    static func resolve(_ key: String) -> URL? {
        var map = loadMap()
        guard let data = map[key] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            map[key] = nil; saveMap(map)
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
            map[key] = fresh; saveMap(map)
        }
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        return url
    }

    /// Called on quit.
    static func stopAll() {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        accessed.removeAll()
    }
}

// MARK: - Session state (restore everything on launch)

struct SessionState: Codable, Equatable {
    var selectionSite: String?        // site id, or nil
    /// Legacy: the rawValue of a top-level section, from the builds where
    /// the desks sat beside the projects instead of inside them. Kept so an
    /// old saved session still decodes; it is cleared on the first launch
    /// that reads it, and nothing writes it any more.
    var selectionSection: String?
    var workspaceTab: String?         // WorkspaceTab rawValue
    var articlePath: String?          // open article repo path
    var editorMode: Int?              // EditorMode rawValue
}

@MainActor
final class SessionHub: ObservableObject {
    static let shared = SessionHub()
    @Published var state = SessionState() {
        didSet { if state != oldValue { persist() } }
    }
    var restoring = true              // suppress persist storms during restore

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/state.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let s = try? JSONDecoder().decode(SessionState.self, from: data) {
            state = s
        }
    }

    private func persist() {
        guard !restoring else { return }
        try? FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.file) }
    }

    func flush() { restoring = false; persist() }
}

// MARK: - Offline feed cache

enum FeedCache {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/cache", isDirectory: true)
    }

    static func save(_ kind: FeedKind, data: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(kind.file))
    }

    static func load(_ kind: FeedKind) -> (data: Data, date: Date)? {
        let url = dir.appendingPathComponent(kind.file)
        guard let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return (data, date)
    }
}

// MARK: - Open-in-new-window reference + dock-drop payload

struct ArticleRef: Codable, Hashable {
    let site: SiteProject
    let path: String
}

/// AppDelegate: dock/Finder "open with" for .md files + graceful teardown.
final class CockpitAppDelegate: NSObject, NSApplicationDelegate {
    static let openMDNotification = Notification.Name("ldg-open-md")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "md" {
            NotificationCenter.default.post(name: Self.openMDNotification, object: url)
        }
    }

    /* ── Getting the window back ──────────────────────────────────────
       This app keeps a MenuBarExtra, so closing the last window does not
       quit it: it keeps running with nothing on screen. And the New Item
       command is deliberately removed, so there is no Cmd-N either. Put
       those two together and a closed window is unrecoverable except by
       killing the process, which is exactly the state this app got into.

       Returning true asks AppKit to restore the app's windows on the next
       activation, which is what clicking the Dock icon or opening the app
       again is supposed to do. Belt and braces: if AppKit finds nothing to
       restore, un-minimise and raise whatever window still exists. */
    /* ── Getting the window back ──────────────────────────────────────
       This app keeps a MenuBarExtra, so closing the last window does not
       quit it: it keeps running with nothing on screen. Put that together
       with a removed New Item command and a closed window was
       unrecoverable except by killing the process.

       Returning true and doing nothing else is deliberate. An earlier
       version raised whatever window it could find first, and that made
       things worse rather than better: it handed AppKit a leftover
       degenerate window, AppKit concluded there was already something
       visible, and declined to build a real one. Let AppKit decide. */
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /* Window restoration is switched off for this app on purpose. It
       restores "there were no windows last time" just as faithfully as it
       restores a position, and after any hard stop that is the state it
       finds. The cost of restoring a window frame is not worth an app
       that sometimes opens onto nothing. */
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.windows.forEach { $0.isRestorable = false }
    }


    func applicationWillTerminate(_ notification: Notification) {
        for doc in WorkspaceModel.allOpenEditors() { doc.autosaveNow() }
        BookmarkStore.stopAll()
    }
}
