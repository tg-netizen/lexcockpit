import AppKit
import WebKit

/// `swift run LexCockpit --roundtrip <dir-with-md-files>`
///
/// Loads every article's BODY into a real offscreen Toast UI editor (same
/// WysiwygController the app uses), reads the markdown back, and diffs it
/// against the input. This is the data-safety gate for the WYSIWYG editor:
/// opening an article must not rewrite it.
enum RoundtripTest {
    static func start(dir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let ok = await run(dir: dir)
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    @MainActor
    static func run(dir: String) async -> Bool {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: dir) else {
            print("FAIL  cannot list \(dir)")
            return false
        }
        let files = all.filter { $0.hasSuffix(".md") }.sorted()
        guard !files.isEmpty else {
            print("FAIL  no .md files in \(dir)")
            return false
        }

        var allIdentical = true
        for file in files {
            guard let raw = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else {
                print("SKIP  \(file): unreadable")
                continue
            }
            let body = FrontmatterDoc.parse(raw).body

            let controller = WysiwygController()
            var waited = 0.0
            while !controller.ready && waited < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            guard controller.ready else {
                print("FAIL  \(file): editor never became ready (network/CDN?)")
                allIdentical = false
                continue
            }
            controller.load(markdown: body)
            try? await Task.sleep(nanoseconds: 1_800_000_000)

            let output: String? = await withCheckedContinuation { cont in
                controller.currentMarkdown { cont.resume(returning: $0) }
            }
            guard let raw = output else {
                print("FAIL  \(file): no markdown returned")
                allIdentical = false
                continue
            }
            // Same envelope restoration the app applies on every change.
            let envelope = MarkdownEnvelope.split(body)
            let got = MarkdownEnvelope.rewrap(raw, prefix: envelope.prefix, suffix: envelope.suffix)

            if trimTrail(got) == trimTrail(body) {
                print("PASS  \(file): byte-identical through WYSIWYG init")
            } else {
                let (changed, samples) = lineDiff(body, got)
                print("DIFF  \(file): \(changed) line(s) normalized by Toast UI:")
                for s in samples { print("      \(s)") }
                allIdentical = false
            }
        }
        // Informational: how Toast UI treats rich markdown constructs. Does
        // not gate the result — it documents the editor's canonical style for
        // future full-length articles.
        await richFixtureReport()

        print(allIdentical
              ? "RESULT: all files round-trip byte-identically."
              : "RESULT: normalization detected — see DIFF lines above.")
        return allIdentical
    }

    @MainActor
    private static func richFixtureReport() async {
        let fixture = """
        ## A heading

        Some paragraph with a [link](https://example.com) and **bold** plus *italic* text.

        * bullet one
        * bullet two

        1. first
        2. second

        > A quote line.

        `inline code` and a rule:

        ***
        """
        let controller = WysiwygController()
        var waited = 0.0
        while !controller.ready && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard controller.ready else { print("INFO  rich fixture skipped (editor not ready)"); return }
        controller.load(markdown: fixture)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let out: String? = await withCheckedContinuation { cont in
            controller.currentMarkdown { cont.resume(returning: $0) }
        }
        guard let got = out else { print("INFO  rich fixture: no output"); return }
        if trimTrail(got) == trimTrail(fixture) {
            print("INFO  rich fixture (headings/links/lists/quote/code/hr): byte-identical")
        } else {
            let (changed, samples) = lineDiff(fixture, got)
            print("INFO  rich fixture: \(changed) line(s) would be normalized:")
            for s in samples { print("      \(s)") }
        }
    }

    private static func trimTrail(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    private static func lineDiff(_ a: String, _ b: String) -> (Int, [String]) {
        let la = a.components(separatedBy: "\n")
        let lb = b.components(separatedBy: "\n")
        var changed = 0
        var samples: [String] = []
        for i in 0..<max(la.count, lb.count) {
            let x = i < la.count ? la[i] : "∅"
            let y = i < lb.count ? lb[i] : "∅"
            if x != y {
                changed += 1
                if samples.count < 3 {
                    samples.append("line \(i + 1): “\(x.prefix(60))” → “\(y.prefix(60))”")
                }
            }
        }
        return (changed, samples)
    }
}
