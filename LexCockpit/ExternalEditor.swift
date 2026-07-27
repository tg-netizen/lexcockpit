import SwiftUI
import AppKit

// MARK: - External editors (MarkEdit / CotEditor / TextEdit)
//
// Full apps can't be embedded — the professional integration is a round-trip:
// export the current markdown to a working file, open it in the external
// editor, watch the file, and pull every save straight back into the open
// document. The normal SHA-checked save path publishes as usual.

struct ExternalEditor: Identifiable {
    let id: String            // bundle id
    let name: String
    let url: URL

    static func installed() -> [ExternalEditor] {
        let candidates: [(String, String)] = [
            ("app.cyan.markedit", "MarkEdit"),
            ("app.cyan.markedit-dev", "MarkEdit (dev)"),
            ("com.coteditor.CotEditor", "CotEditor"),
            ("com.apple.TextEdit", "TextEdit"),
        ]
        var out: [ExternalEditor] = []
        for (bid, name) in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                out.append(ExternalEditor(id: bid, name: name, url: url))
            }
        }
        return out
    }
}

@MainActor
final class ExternalEditSession: ObservableObject {
    @Published var activeEditorName: String?

    private var source: DispatchSourceFileSystemObject?
    private var fileURL: URL?
    private var onChange: ((String) -> Void)?
    private var lastText = ""

    static var workDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/external", isDirectory: true)
    }

    func start(text: String, slug: String, editor: ExternalEditor,
               onChange: @escaping (String) -> Void) {
        stop()
        try? FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        let url = Self.workDir.appendingPathComponent(slug + ".md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lastText = text
        self.onChange = onChange
        NSWorkspace.shared.open([url], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
        activeEditorName = editor.name
        beginWatching(url)
    }

    /// Watch without launching anything — used by `--watch-test`.
    func beginWatching(_ url: URL, onChange: ((String) -> Void)? = nil) {
        if let onChange = onChange { self.onChange = onChange }
        fileURL = url
        armWatcher(url)
    }

    private func armWatcher(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let events = src.data
            self.pull()
            // Atomic saves (TextEdit/CotEditor/MarkEdit) REPLACE the file —
            // the old fd goes stale, so re-arm on rename/delete.
            if events.contains(.rename) || events.contains(.delete) {
                src.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self, let url = self.fileURL else { return }
                    self.armWatcher(url)
                    self.pull()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source?.cancel()
        source = src
    }

    private func pull() {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              text != lastText else { return }
        lastText = text
        onChange?(text)
    }

    func stop() {
        source?.cancel()
        source = nil
        fileURL = nil
        activeEditorName = nil
    }

    // MARK: Headless verification (`--watch-test`)

    static func selfTest() async -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-watch-\(Int.random(in: 0..<99999))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.md")
        try? "start".write(to: file, atomically: true, encoding: .utf8)

        let session = ExternalEditSession()
        var received: [String] = []
        session.beginWatching(file) { text in received.append(text) }

        // 1. plain in-place write
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? "edit-1".write(to: file, atomically: false, encoding: .utf8)
        // 2. ATOMIC replace (how real editors save)
        try? await Task.sleep(nanoseconds: 500_000_000)
        try? "edit-2".write(to: file, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 800_000_000)
        // 3. write after re-arm (proves the watcher survived the replace)
        try? "edit-3".write(to: file, atomically: false, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 800_000_000)

        session.stop()
        try? FileManager.default.removeItem(at: dir)
        let ok = received.contains("edit-1") && received.contains("edit-2") && received.contains("edit-3")
        print("watch events received: \(received)")
        return ok
    }
}
